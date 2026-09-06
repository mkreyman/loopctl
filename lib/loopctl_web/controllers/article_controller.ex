defmodule LoopctlWeb.ArticleController do
  @moduledoc """
  Controller for Knowledge Wiki article CRUD operations.

  - `POST /api/v1/articles` -- create tenant-wide article (agent+)
  - `POST /api/v1/projects/:project_id/articles` -- create project-scoped article (agent+)
  - `GET /api/v1/articles` -- list articles with filters (agent+)
  - `GET /api/v1/projects/:project_id/articles` -- list project-scoped articles (agent+)
  - `GET /api/v1/articles/:id` -- get article with preloaded links (agent+)
  - `PATCH /api/v1/articles/:id` -- update article content (agent+); a `status`
    key in the body is user+ only (403 `status_change_forbidden` otherwise)
  - `DELETE /api/v1/articles/:id` -- archive article / soft delete (agent+)

  Role note: the whole KB *content* surface (create/update/archive/soft-delete)
  is `agent+`. Each is a non-destructive, audited curation op — a soft delete only
  sets `status: :archived` and retains the row (that status is TERMINAL: restoring
  it takes a `user+` PATCH, so non-destructive is not reversible) — so agents may fully self-serve
  the wiki. Irreversible / custody ops stay `user`-gated elsewhere (bulk HARD
  delete, tenant/project delete). An agent editing/archiving is additionally
  scoped by article visibility (it cannot touch another agent's `private`/`owner`
  memory — that resolves to 404, matching reads). One carve-out on PATCH: a
  caller-supplied `status` is a user+ capability (it publishes/retires/archives an
  article, bypassing the lifecycle endpoints' transition guards), so a lower role
  sending `status` gets 403 and must use POST /articles/:id/{publish,unpublish,
  archive} instead. See the "Security & Trust Model" checklist in the project
  `CLAUDE.md` for the KB carve-out.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth.Role
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IdempotencyTag
  alias Loopctl.TelemetryEvents
  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.Helpers.BodyWindow
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.ProjectId
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  # Read from the module that ENFORCES them, so the published spec cannot drift from the
  # caps (same discipline as `@max_inline_content_bytes` in the ingestion controller).
  # The two caps are SEPARATE attributes there and are read separately here, so raising
  # one alone cannot leave the other's description stating the wrong number.
  @max_links_per_direction ArticleJSON.max_links_per_direction()
  @max_conflicts ArticleJSON.max_conflicts()

  @valid_statuses Article |> Ecto.Enum.values(:status) |> Enum.map(&to_string/1)
  @valid_categories Article |> Ecto.Enum.values(:category) |> Enum.map(&to_string/1)

  # KB content curation (create/update/soft-delete) is agent+ — all non-destructive,
  # audited ops (#331; NOT reversible — `:archived` is terminal). Visibility scoping (below) keeps an agent off another
  # agent's private memory.
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:create, :index, :show, :update, :delete]

  tags(["Knowledge Wiki"])

  operation(:create,
    summary: "Create article",
    description:
      "Creates a tenant-wide or project-scoped article. " <>
        "When called via POST /projects/:project_id/articles, project_id is set from path. " <>
        "Articles are **published immediately by default** (visible in search/index/context) " <>
        "for every role, including agent. To stage an article for later review instead, pass " <>
        "`draft: true` (or `status: \"draft\"`); the response `note` says which outcome " <>
        "occurred. The initial status is set by the server — a caller-supplied `status` is " <>
        "ignored except that `status: \"draft\"` is honoured as the draft opt-in (so " <>
        "archived/superseded can't be conjured at create time; those are workflow " <>
        "transitions). Role: agent+.",
    request_body:
      {"Article params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:title, :body, :category],
         properties: %{
           title: %OpenApiSpex.Schema{type: :string},
           body: %OpenApiSpex.Schema{type: :string},
           category: %OpenApiSpex.Schema{
             type: :string,
             enum: ["pattern", "convention", "decision", "finding", "reference"]
           },
           draft: %OpenApiSpex.Schema{
             type: :boolean,
             description:
               "Stage as a draft instead of publishing on create. Default false " <>
                 "(article is published immediately). Equivalent alias: status: \"draft\". " <>
                 "Publishing a staged draft afterwards (POST /articles/:id/publish) " <>
                 "requires orchestrator role; publish-on-create does not. (Note: the " <>
                 "ingestion path has the OPPOSITE polarity — POST /knowledge/ingest is " <>
                 "draft-by-default; pass publish: true there.) A draft is NOT held " <>
                 "indefinitely: the nightly draft consumer publishes it automatically " <>
                 "once it is a week old, linking it to its nearest published neighbour " <>
                 "if it is a near-duplicate. Staging is a HOLD, not a veto — there is no " <>
                 "human approver in this system, so a draft nothing ever drains is " <>
                 "invisible to every agent forever. Publish or delete it inside the week " <>
                 "if the outcome matters."
           },
           tags: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string},
             description:
               Article.tag_contract_description() <> " " <> IdempotencyTag.contract_description()
           },
           project_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
           source_type: %OpenApiSpex.Schema{type: :string, nullable: true},
           source_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
           idempotency_key: %OpenApiSpex.Schema{
             type: :string,
             nullable: true,
             description:
               "Optional stable per-article key for idempotent capture (max 255). " <>
                 "Re-creating with the same key is a no-op that returns a REFERENCE to " <>
                 "the existing article (200, `deduplicated: true`, id only — not its " <>
                 "body) — regardless of the body sent, and ahead of the title-conflict " <>
                 "check; a changed title/body is NOT applied (PATCH /articles/:id to " <>
                 "change it). A body/title that differs is NOT refused — a re-running " <>
                 "sourcer would break — but it IS reported: the response carries " <>
                 "`content_drift` / `title_drift` and a `note` telling you to read the " <>
                 "stored article before overwriting it. " <>
                 "Use a HIGH-ENTROPY value (e.g. a content hash): it is a " <>
                 "per-tenant lookup key, not a secret. Distinct from source_type/" <>
                 "source_id, which identify a shared source. Set at create time only " <>
                 "(ignored by PATCH); applies to tenant-scoped articles."
           },
           skip_low_novelty: %OpenApiSpex.Schema{
             type: :boolean,
             description:
               "Create NOTHING when the novelty gate finds high overlap, instead of " <>
                 "staging a draft (default false). For an UNATTENDED writer with no " <>
                 "reviewer behind it, whose gated drafts would pile up unresolved. The " <>
                 "response is 200 with `data: null`, `skipped: true` and the gate " <>
                 "metadata. Equivalent alias: on_low_novelty: \"skip\". Mutually " <>
                 "exclusive with force (422) — force bypasses the gate entirely. An " <>
                 "idempotency_key match or an exact title collision is still answered " <>
                 "as a dedup/409, and an invalid payload still 422s — never dropped."
           },
           on_low_novelty: %OpenApiSpex.Schema{type: :string, enum: ["draft", "skip"]},
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 =>
        {"Article created (response includes a `note`; `status` is published unless draft)",
         "application/json", %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      403 =>
        {"System scope requested without superadmin role", "application/json",
         Schemas.ErrorResponse},
      200 =>
        {"Nothing was created. Either an idempotent dedup returned unchanged with " <>
           "`deduplicated: true` (an active article with the same title and an " <>
           "identical body exists, OR an article with the same `idempotency_key` " <>
           "exists — in which case a changed title/body is NOT applied), or, with " <>
           "`skip_low_novelty: true`, a high-overlap proposal DISCARDED with " <>
           "`skipped: true` and `data: null` (no article reference — read `gate` and " <>
           "`note` for the near-neighbour). The `note` says which. EVERY " <>
           "`deduplicated: true` response carries `content_drift` and `title_drift` " <>
           "(booleans, compared after trimming surrounding whitespace) — the " <>
           "idempotency-key dedup, the title-collision dedup and the novelty gate's " <>
           "near-duplicate verdict alike: true means the payload you just sent DIFFERS " <>
           "from the RETURNED article, which was left unchanged. Which SIDE moved is not " <>
           "decidable from the payload — the stored article may have been curated or " <>
           "machine-retitled since your last capture — so GET /articles/:id before " <>
           "overwriting it, then PATCH /articles/:id if that row is YOUR OWN prior " <>
           "capture and your version is still the intended one. On `gate.verdict: " <>
           "duplicate` it is NOT: the row is a near-NEIGHBOUR matched by similarity, so " <>
           "drift is true by construction there and the remedy is to merge into it or " <>
           "re-send with `force: true`, never to PATCH your payload onto it. Both are " <>
           "false on a title+body dedup by construction. The " <>
           "`skipped: true` shape carries NEITHER field: nothing was stored for this " <>
           "payload, so there is no row it could have drifted from (the discard is " <>
           "already explicit in `skipped: true` / `data: null`, and `gate.nearest` " <>
           "names the neighbour it lost to).", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           additionalProperties: true,
           properties: %{
             deduplicated: %OpenApiSpex.Schema{
               type: :boolean,
               description:
                 "true when an existing article was returned unchanged and nothing was created."
             },
             content_drift: %OpenApiSpex.Schema{
               type: :boolean,
               description:
                 "Present on every `deduplicated: true` response. true means the BODY you " <>
                   "submitted differs (after trimming surrounding whitespace) from the stored " <>
                   "article, which was NOT changed. Server-derived, never caller-supplied. " <>
                   "Omitting `body` entirely is not drift; SENDING it as null or a non-string " <>
                   "IS, because the dedup short-circuits before validation and a broken " <>
                   "extraction would otherwise be answered with an affirmative `false`."
             },
             title_drift: %OpenApiSpex.Schema{
               type: :boolean,
               description:
                 "Present on every `deduplicated: true` response. true means the TITLE you " <>
                   "submitted differs (after trimming) from the stored article, which was NOT " <>
                   "changed. Deliberately FALSE when your title matches the article's " <>
                   "`previous_title` AND the stored title is still the machine-generated one " <>
                   "— the nightly consolidation retitled it, so the stored side moved and " <>
                   "re-applying yours would only undo that every night. Once a human curates " <>
                   "that title the suppression stops and drift is reported again."
             }
           }
         }},
      409 =>
        {"Title taken by an article with different content", "application/json",
         Schemas.ErrorResponse},
      422 =>
        {"Validation error — includes a malformed tag: one carrying disallowed " <>
           "characters or surrounding whitespace, or one claiming the reserved idempotency " <>
           "namespace without matching its shape. " <>
           Article.tag_contract_description() <>
           " " <> IdempotencyTag.contract_description(), "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List articles",
    description:
      "Lists articles with optional filters and pagination. " <>
        "When called via GET /projects/:project_id/articles, project_id is set from path. " <>
        "Unlike search (which ranks and returns **published** articles only and lags writes " <>
        "while embeddings index), this is the **lag-free, all-status** read of the DB of " <>
        "record — use it for dedup/idempotency/repair (\"does an article with this tag/" <>
        "source/idempotency_key exist?\"). `meta.total_count` is the exact filtered count. " <>
        "**Returns a body-less summary by default** (safe to enumerate up to limit=1000); pass " <>
        "`include_body=true` to also return `body`, which bounds the page by a ~5 MB " <>
        "serialized-body budget and adds `meta.next_offset`/`meta.has_more`/`meta.byte_truncated` " <>
        "for continuation. For a single full body use GET /articles/:id. " <>
        "`idempotency_key` is a FILTER only — it is accepted here and never returned in a " <>
        "row, so the existence check is `meta.total_count` on a key you already hold, not " <>
        "an enumeration of the keys other callers chose. " <>
        "Role: agent+.",
    parameters: [
      category: [
        in: :query,
        type: :string,
        description: "Filter by category (pattern|convention|decision|finding|reference)"
      ],
      status: [
        in: :query,
        type: :string,
        description: "Filter by status (draft|published|archived|superseded)"
      ],
      tags: [
        in: :query,
        type: :string,
        description: "Filter by tags (comma-separated). Match mode set by `match` (default ANY)."
      ],
      match: [
        in: :query,
        type: :string,
        description:
          "Tag match mode: `any` (default, OR — overlaps any listed tag) or `all` " <>
            "(AND — carries every listed tag, e.g. tags=book,hub&match=all = \"book hubs\")."
      ],
      source_type: [in: :query, type: :string, description: "Filter by source_type"],
      source_id: [in: :query, type: :string, description: "Filter by source_id"],
      idempotency_key: [
        in: :query,
        type: :string,
        description:
          "Filter by exact idempotency_key (lag-free existence check). Not echoed back " <>
            "in the rows — read `meta.total_count`."
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results per page (default 20, max 1000). A limit above the max is " <>
            "clamped to the maximum — never rejected — so offset pagination stays complete."
      ],
      offset: [in: :query, type: :integer, description: "Records to skip"],
      include_body: [
        in: :query,
        type: :boolean,
        description:
          "Include full article body (default false). When true the page is bounded by a " <>
            "~5 MB serialized-body budget and may return fewer than `limit` rows; continue via " <>
            "`meta.next_offset` while `meta.has_more` is true."
      ]
    ],
    responses: %{
      200 =>
        {"Article list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      400 =>
        {"Invalid filter value (e.g. unknown status/category) — body lists allowed values",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get article",
    description:
      "Returns article detail with outgoing and incoming links preloaded. Role: agent+.\n\n" <>
        "**Scope (#572).** Resolves tenant-owned articles AND published SYSTEM CANONICALS — " <>
        "the same public set the wiki serves at `/wiki/<slug>` and `heat_index` lists, so a " <>
        "canonical stub no longer 404s here. A DRAFT or ARCHIVED canonical still 404s, and a " <>
        "tenant-owned article can never match the canonical fallback (it requires " <>
        "`scope: :system`), so tenant isolation is unchanged. This read is COUNTED by the " <>
        "heat index; drill via `GET /knowledge/progressive/:id` when you are merely " <>
        "following an index this system produced.\n\n" <>
        "**Link payload (#538).** Each link carries only its FAR side, as " <>
        "`article: {id, title}` — for an outgoing link the source is always the requested " <>
        "article and for an incoming link the target is, so that side was a constant echo " <>
        "of the URL with an always-`null` title. A link also carries `similarity` when the " <>
        "auto-linker recorded one. Both direction arrays are ranked (open " <>
        "`potential_conflict` first, then descending similarity, then oldest-first for " <>
        "the unscored) and capped at #{@max_links_per_direction} entries " <>
        "each; `links_total` reports the true count and `links_truncated` says whether the " <>
        "cap bit. Use `knowledge_graph` to traverse the full graph.\n\n" <>
        "`links` selects the detail level: `full` (default), `count` (omits both arrays, " <>
        "keeps `links_total` and `links_truncated`), or `none` (omits the link fields " <>
        "entirely). An unrecognized value is treated as `full`. `potential_conflicts` is " <>
        "returned in ALL THREE modes, itself capped at #{@max_conflicts} " <>
        "(highest similarity first, then oldest-first) with `conflicts_total` / " <>
        "`conflicts_truncated`.\n\n" <>
        "**`previous_title` (#765).** Non-null only on an article the nightly consolidation " <>
        "pass retitled from its own content, where it carries the placeholder title that " <>
        "was replaced. It is the UNDO record for that unattended write, so it is a column " <>
        "rather than a `metadata` key and a PATCH cannot erase it; restore it by PATCHing " <>
        "`title` back. Read-only — it is not accepted on create or update.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description:
          "Article UUID. A unique ID PREFIX (>= 8 hex characters) also resolves, so a " <>
            "mistyped or truncated tail still finds the article; a prefix matching more " <>
            "than one visible article is a 404, never a guess."
      ],
      links: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, enum: ["full", "count", "none"]},
        required: false,
        description:
          "Link detail level (default `full`). `count` returns `links_total` and " <>
            "`links_truncated`; `none` omits the link fields. `potential_conflicts` " <>
            "(capped, with `conflicts_total`) is always returned."
      ],
      body_max_bytes: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "Serialized-body byte budget (default #{ArticleJSON.article_body_byte_budget()}). " <>
            "`0` returns the whole body. The response always carries `body_bytes`, " <>
            "`body_offset`, `body_returned_bytes`, `body_truncated` and `next_body_offset`, " <>
            "so a truncated read can be continued rather than discarded."
      ],
      body_offset: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "Byte offset to start the body window at (default 0). Pass the previous " <>
            "response's `next_body_offset` to continue. An offset landing mid-character " <>
            "advances to the next character boundary."
      ],
      project_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Attribution only — recorded on the article-access event."
      ],
      story_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Attribution only — recorded on the article-access event."
      ]
    ],
    responses: %{
      200 =>
        {"Article detail", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Malformed `project_id` (not a UUID)", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update article",
    description:
      "**PATCH /api/v1/articles/:id** — updates an existing article in place. Send only " <>
        "the fields to change; supported keys are `title`, `body`, `tags` (replaces the " <>
        "whole array), `category`, `metadata`, and `project_id`. Partial updates " <>
        "are supported (e.g. body-only to tidy a hub, or tags-only). `tenant_id` is never " <>
        "accepted from the body. Returns the full updated article. A changed `body`/`tags` " <>
        "re-triggers embedding/linking. Role: agent+ for content edits (KB content curation; " <>
        "an agent may only edit articles it can see — another agent's private/owner memory " <>
        "404s). `status` is a **user+**-only key on PATCH (a `status` in the body from a " <>
        "lower role returns 403 `status_change_forbidden`); agents/orchestrators change " <>
        "lifecycle via the dedicated endpoints — POST /articles/:id/publish (orchestrator+), " <>
        "/unpublish (user+), /archive (agent+) — which enforce the transition guards.",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    request_body:
      {"Update params", "application/json",
       %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 =>
        {"Updated article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      403 =>
        {"Forbidden — a `status` change on PATCH requires role user+ (code " <>
           "status_change_forbidden); use the lifecycle endpoints instead", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Validation error — includes a malformed tag: one carrying disallowed " <>
           "characters or surrounding whitespace, or one claiming the reserved idempotency " <>
           "namespace without matching its shape. " <>
           Article.tag_contract_description() <>
           " " <> IdempotencyTag.contract_description(), "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Archive article",
    description:
      "Archives an article (soft delete — sets status: archived, retains the row; " <>
        "non-destructive and audited, but NOT reversible: archived is terminal and " <>
        "restoring takes a user+ PATCH with an explicit status). " <>
        "Role: agent+ (an agent may only archive articles it " <>
        "can see — another agent's private/owner memory 404s).",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    responses: %{
      200 =>
        {"Archived article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # --- Actions ---

  @doc "POST /api/v1/articles or POST /api/v1/projects/:project_id/articles"
  def create(conn, params) do
    scope = params["scope"] || "tenant"
    api_key = conn.assigns.current_api_key
    draft? = draft_requested?(params)
    # Novelty-gated write-back is ON by default; `force: true` bypasses it (e.g. the
    # caller has already searched and knows the proposal is intentionally near an
    # existing article).
    gate? = not truthy?(params["force"])

    # System articles require superadmin role; everything else is agent+.
    if scope == "system" and api_key.role != :superadmin do
      # Count the reject under the DISTINCT :forbidden outcome (a 403 authz drop persists
      # no article row). It is tracked for observability but excluded from the
      # high_reject_rate reject numerator/denominator — a scope-misuse 403 storm is
      # permission misuse, not an ingestion-pipeline outage, and must not page the
      # operator nor dilute a genuine title_conflict/validation_error signal.
      emit_write_telemetry(conn, params, :forbidden)

      conn
      |> put_status(:forbidden)
      |> json(%{
        error: %{
          status: 403,
          code: "system_scope_forbidden",
          message: "System-scoped articles require superadmin role"
        }
      })
    else
      # Validate project_id (path segment or JSON body) up front so a non-UUID
      # value returns a clean 422 instead of reaching validate_project_ownership/2
      # and raising Ecto.Query.CastError (500).
      case validate_create_params(params, gate?) do
        :ok ->
          create_validated(conn, api_key, params, draft?, gate?)

        error ->
          # Count the upfront validation drop too, so a client hammering create with a
          # malformed project_id (100% 422s, zero article rows) still moves reject_rate.
          emit_write_telemetry(conn, params, :validation_error)
          error
      end
    end
  end

  # Up-front request validation shared by both create routes. `force` bypasses the gate
  # entirely (ungated `create_article/3` never reads `:on_low_novelty`), so combining it
  # with `skip_low_novelty` would silently PUBLISH the near-duplicate the caller asked to
  # never create — the exact outcome both flags exist to prevent. Reject the pair instead
  # of picking a winner: only the caller knows which one it meant.
  defp validate_create_params(params, gate?) do
    cond do
      not valid_low_novelty_opt?(params) ->
        {:error, :unprocessable_entity,
         "on_low_novelty must be draft or skip, and skip_low_novelty must be a boolean. " <>
           "A value that is neither is a typo, and defaulting it to draft would bank " <>
           "exactly the drafts the caller asked never to create."}

      not gate? and skip_low_novelty?(params) ->
        {:error, :unprocessable_entity,
         "force and skip_low_novelty are mutually exclusive: force bypasses the novelty " <>
           "gate, so there is no overlap decision left to skip. Send one, not both."}

      true ->
        ProjectId.validate(params["project_id"])
    end
  end

  defp valid_low_novelty_opt?(params) do
    params["on_low_novelty"] in [nil, "", "draft", "skip"] and
      params["skip_low_novelty"] in [nil, "", true, false, "true", "false"]
  end

  defp create_validated(conn, api_key, params, draft?, gate?) do
    tenant_id = api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    # If project_id comes from the path (project-scoped route), merge it into
    # attrs, then set the initial status server-side (never trusting the caller's
    # `status`): published by default, draft only when the caller explicitly opted
    # in via draft:true / status:"draft".
    attrs =
      params
      |> maybe_merge_project_id(params["project_id"])
      |> put_create_status(draft?)

    # Trust model (#163): an agent may only write a memory under its OWN verified
    # key identity. For agent-role writers that carry agent-memory metadata, stamp
    # metadata.agent_id from the key (overriding any spoofed value); an agent with
    # no key identity can't attribute a memory → 403.
    case bind_agent_identity(api_key, attrs) do
      {:ok, bound_attrs} ->
        create_article(conn, tenant_id, bound_attrs, audit_opts, draft?, gate?)

      {:error, :no_agent_identity} ->
        # Count the reject under the DISTINCT :forbidden outcome (an identity-required
        # 403 drop persists no article row) — excluded from the high_reject_rate
        # detector, like the scope-forbidden case above: authz misuse is not an
        # ingestion-pipeline outage.
        emit_write_telemetry(conn, attrs, :forbidden)

        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            status: 403,
            code: "agent_identity_required",
            message:
              "This API key has no agent identity; it cannot write an attributed agent memory"
          }
        })
    end
  end

  # Stamp metadata.agent_id from the authenticated agent key (write-path binding,
  # #163). Only agent-role writers carrying agent-memory metadata are bound; higher
  # roles are trusted to attribute on behalf of others (orchestration/backfill).
  defp bind_agent_identity(%{role: :agent} = api_key, attrs) do
    metadata = attrs["metadata"] || attrs[:metadata] || %{}

    if is_map(metadata) and agent_memory_metadata?(metadata) do
      case api_key.agent_id do
        nil ->
          {:error, :no_agent_identity}

        agent_id ->
          {:ok, Map.put(attrs, "metadata", Map.put(metadata, "agent_id", to_string(agent_id)))}
      end
    else
      {:ok, attrs}
    end
  end

  defp bind_agent_identity(_api_key, attrs), do: {:ok, attrs}

  # An article is an agent memory when its metadata carries any of the agent-memory
  # markers (agent_id / memory_type / visibility). Request metadata is string-keyed
  # JSON; we also accept the atom forms for non-HTTP callers.
  @agent_memory_markers ["agent_id", "memory_type", "visibility"]
  @agent_memory_marker_atoms [:agent_id, :memory_type, :visibility]
  defp agent_memory_metadata?(metadata) do
    Enum.any?(@agent_memory_markers, &Map.has_key?(metadata, &1)) or
      Enum.any?(@agent_memory_marker_atoms, &Map.has_key?(metadata, &1))
  end

  defp create_article(conn, tenant_id, attrs, audit_opts, draft?, gate?) do
    # Pass the caller's visibility scope so idempotency dedup can't echo a private
    # memory the agent can't see (#163).
    #
    # `staged_draft: draft?` records the OPT-IN durably (`articles.staged_draft_at`).
    # `draft: true` / `status: "draft"` is advertised staging, and until this marker
    # existed it left no trace at all, so the nightly `Loopctl.Knowledge.DraftConsumer`
    # could not tell a deliberate stage from a capture nobody came back for and had to
    # apply one blind age floor to both. It carries `draft?` — what the CALLER asked
    # for — and not the resulting status, so a `:low_novelty` proposal the gate drafts
    # on behalf of a caller who asked to PUBLISH is not recorded as a stage.
    opts =
      audit_opts ++
        Visibility.scope_opts(conn) ++ low_novelty_opts(attrs) ++ [staged_draft: draft?]

    if gate? do
      render_proposal(conn, Knowledge.propose_article(tenant_id, attrs, opts), attrs, draft?)
    else
      render_create(conn, Knowledge.create_article(tenant_id, attrs, opts), attrs, draft?)
    end
  end

  # `on_low_novelty=skip` — create nothing on high overlap instead of drafting. For an
  # unattended writer (session capture) whose drafts nothing would ever review; see
  # `Knowledge.propose_article/3`. Accepted as a request field so the DEFAULT stays
  # draft-and-review for interactive callers.
  defp low_novelty_opts(attrs) do
    if skip_low_novelty?(attrs), do: [on_low_novelty: :skip], else: []
  end

  defp skip_low_novelty?(attrs) do
    truthy?(attrs["skip_low_novelty"]) or attrs["on_low_novelty"] == "skip"
  end

  # Novelty-gated path: render by verdict. A near-duplicate is NOT created — the
  # caller is pointed at the canonical article. A low-novelty proposal is created as
  # a draft with the near-neighbors surfaced so a reviewer/consumer can merge.

  # High overlap and the caller opted out of drafting — nothing was created. Report the
  # neighbour it lost to so the caller can count and attribute the drop.
  #
  # NO drift fields here, deliberately, and the published contract says so. Drift means
  # "the payload you sent differs from the row you were handed"; this response hands back
  # NO row (`data: null`), and comparing the payload to a mere near-NEIGHBOUR would report
  # a tautological `true` on every skip. The discard is not silent either — which is the
  # whole failure the dedup flags exist for — it is stated in `skipped: true`, and the
  # neighbour's id is structured in `gate.nearest` as well as named in the note, so a
  # caller that decides to merge into it has the id without a drift flag to carry it.
  defp render_proposal(conn, {:ok, %{verdict: :skipped_low_novelty} = result}, attrs, _draft?) do
    %{article: neighbor, assessment: assessment} = result

    # Counted under its OWN outcome, not folded into :deduplicated. A dedup means the
    # content already exists AS A ROW the caller was handed; a skip means it was
    # DISCARDED and exists nowhere — folding them together would let a drop storm (a
    # mis-tuned threshold, or a writer whose every capture now scores high) read as a
    # healthy dedup-heavy day. It is tracked for observability but kept OUT of the
    # high_reject_rate ratio entirely (like :forbidden): a writer running
    # on_low_novelty=skip is EXPECTED to skip most captures, so counting skips in the
    # denominator would dilute a genuine reject storm below the threshold.
    emit_write_telemetry(conn, attrs, :skipped_low_novelty)

    conn
    |> put_status(:ok)
    |> json(%{
      data: nil,
      skipped: true,
      # `assessment.neighbors` has already been narrowed by the context to the rows that
      # still resolve, so `nearest`, `note` and the curation-log ref all name the same
      # live rows — a caller attributing the drop can fetch every id it is handed.
      gate: gate_meta(:skipped_low_novelty, assessment),
      note:
        "High overlap with existing knowledge (similarity " <>
          "#{format_score(assessment.score)}) — nothing was created, per " <>
          "on_low_novelty=skip." <>
          if(neighbor, do: " Nearest existing article: #{neighbor.id}.", else: "")
    })
  end

  defp render_proposal(conn, {:ok, %{verdict: :duplicate} = result}, attrs, _draft?) do
    %{article: existing, assessment: assessment} = result

    # This is the DEFAULT create path (only `force: true` bypasses the gate), and it is a
    # `deduplicated: true` response, so it carries the same drift fields the idempotency
    # and title-collision dedups carry — a client reading `content_drift` must never get
    # `undefined` here and read the falsy value as "in sync".
    #
    # But the row here is a near-NEIGHBOUR the gate matched by SIMILARITY, not the caller's
    # own prior capture, so the flags mean something WEAKER: "not byte-identical to a
    # different article", which is true of nearly every gated near-duplicate. Two things
    # follow, and both are the reason this branch does not reuse the dedup wording:
    # `neighbor_drift_note/2` replaces `drift_note/2`, whose remedy (PATCH your payload
    # onto this id) would have an unattended sourcer overwrite a stranger's curated
    # article; and neither the `Logger` warning nor the telemetry drift metadata fires,
    # because a signal that is true by construction on the default path buries the
    # idempotency-path discard it exists to surface.
    drift = Knowledge.dedup_drift(existing, attrs)

    emit_write_telemetry(conn, attrs, :deduplicated)

    conn
    |> put_status(:ok)
    |> json(
      %{
        data: %{id: existing.id, title: existing.title, status: to_string(existing.status)},
        deduplicated: true,
        gate: gate_meta(:duplicate, assessment),
        note:
          "A near-duplicate already exists (id #{existing.id}, similarity " <>
            "#{format_score(assessment.score)}). Nothing was created — read or merge into " <>
            "the existing article, or pass `force: true` to create anyway." <>
            neighbor_drift_note(existing, drift)
      }
      |> Map.merge(drift)
    )
  end

  defp render_proposal(conn, {:ok, %{verdict: :gated_to_draft} = result}, attrs, _draft?) do
    %{article: article, assessment: assessment} = result

    emit_write_telemetry(conn, attrs, :gated_to_draft)

    conn
    |> put_status(:created)
    |> json(
      article
      |> create_response()
      |> Map.put(:gate, gate_meta(:gated_to_draft, assessment))
      |> Map.put(
        :note,
        "High overlap with existing knowledge (similarity " <>
          "#{format_score(assessment.score)}) — created as a DRAFT instead of " <>
          "publishing, with near-neighbors in metadata.proposal_novelty for review. " <>
          "Resolve via merge/publish, or pass `force: true` to publish on create."
      )
    )
  end

  defp render_proposal(conn, {:ok, %{verdict: :deduplicated, article: existing}}, attrs, draft?) do
    body = dedup_response(existing, attrs, draft?)

    emit_write_telemetry(conn, attrs, :deduplicated, drift_of(body))
    log_drifted_discard(conn, existing, drift_of(body))

    conn
    |> put_status(:ok)
    |> json(body)
  end

  # :created (novel, or gate fell open) — normal create response.
  defp render_proposal(conn, {:ok, %{article: article}}, attrs, _draft?) do
    emit_write_telemetry(conn, attrs, :created)

    conn
    |> put_status(:created)
    |> json(create_response(article))
  end

  defp render_proposal(conn, error, attrs, draft?),
    do: render_create(conn, error, attrs, draft?)

  # Ungated path (force: true) — the original create semantics.
  defp render_create(conn, {:ok, article}, attrs, _draft?) do
    emit_write_telemetry(conn, attrs, :created)

    conn
    |> put_status(:created)
    |> json(create_response(article))
  end

  defp render_create(conn, {:ok, :deduplicated, existing}, attrs, draft?) do
    body = dedup_response(existing, attrs, draft?)

    emit_write_telemetry(conn, attrs, :deduplicated, drift_of(body))
    log_drifted_discard(conn, existing, drift_of(body))

    conn
    |> put_status(:ok)
    |> json(body)
  end

  defp render_create(conn, {:error, :duplicate_title, existing}, attrs, _draft?) do
    emit_write_telemetry(conn, attrs, :title_conflict)

    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "title_conflict",
        message:
          "An article titled \"#{existing.title}\" already exists in this tenant " <>
            "with different content. Choose a different (more specific) title, " <>
            "or edit the existing article via PATCH /articles/:id (role :agent).",
        details: %{existing_article_id: existing.id}
      }
    })
  end

  defp render_create(conn, {:error, %Ecto.Changeset{} = changeset}, attrs, _draft?) do
    emit_write_telemetry(conn, attrs, :validation_error)
    {:error, changeset}
  end

  # Emit the article-write outcome telemetry (PR B2). Folded into the durable
  # `ingestion_write_stats` rollup by `Loopctl.Telemetry.IngestionWriteStats` so a
  # high-rejection-rate outage (which persists NO article row) stays observable.
  # Emission must never change response behavior — it is a fire-and-forget increment.
  defp emit_write_telemetry(conn, attrs, outcome),
    do: emit_write_telemetry(conn, attrs, outcome, nil)

  # `drift` is the dedup drift map, or nil on the outcomes that have none.
  #
  # A drifted dedup and an identical re-capture are the SAME outcome on the wire (both
  # 200 `deduplicated: true`), so a fleet-wide silent discard — a sourcer whose content
  # moved, or whose extraction broke, re-running against a stable key — needs a
  # server-side trace. The DURABLE one is the `Logger` warning in `log_drifted_discard/3`,
  # which names the tenant and the article so an operator can go read the row that was
  # kept. The flags below ride as METADATA on the existing `:deduplicated` outcome for any
  # handler that attaches — but the `ingestion_write_stats` rollup does NOT break them
  # out today, so do not read a drift count out of it. A new `:deduplicated_drifted`
  # OUTCOME would be worse than useless: `IngestionWriteStats.column_for/1` SKIPS an
  # unmapped outcome, so a fresh atom would drop every drifted dedup out of the rollup
  # entirely.
  defp emit_write_telemetry(conn, attrs, outcome, drift) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    :telemetry.execute(
      TelemetryEvents.article_write(),
      %{count: 1},
      %{
        tenant_id: tenant_id,
        source_type: telemetry_source_type(attrs),
        outcome: outcome,
        content_drift: drift != nil and drift.content_drift,
        title_drift: drift != nil and drift.title_drift
      }
    )
  end

  # Emitted only when something was actually discarded — a clean re-run is the normal,
  # silent case and logging it would bury the one line that matters.
  defp log_drifted_discard(_conn, _existing, %{content_drift: false, title_drift: false}), do: :ok

  defp log_drifted_discard(conn, existing, drift) do
    Logger.warning(
      "knowledge article create deduplicated with drift: the submitted " <>
        "#{drifted_fields(drift)} differed from the stored article and was discarded " <>
        "(tenant_id=#{conn.assigns.current_api_key.tenant_id} article_id=#{existing.id} " <>
        "content_drift=#{drift.content_drift} title_drift=#{drift.title_drift})"
    )
  end

  # The drift map a dedup body already carries, so the telemetry and the response can
  # never disagree about whether the payload moved.
  defp drift_of(%{content_drift: c, title_drift: t}), do: %{content_drift: c, title_drift: t}

  # Normalize the telemetry source_type to the durable rollup's bucketing rules.
  #
  # `source_type` on a REJECTED write is arbitrary client input (the changeset
  # already refused it), so forwarding it raw would (a) mint an unbounded number of
  # `ingestion_write_stats` rows — one per distinct garbage value — letting a reject
  # storm fragment across buckets below `min_attempts` and evade the high_reject_rate
  # detector, and (b) let a literal `"(unstamped)"` collide with the NULL sentinel.
  # Fold any value NOT in `Article.known_source_types/0` into `nil` so it lands in the
  # single COALESCE('') unstamped bucket — only the ~8 known values key distinct rows.
  defp telemetry_source_type(attrs) do
    case attrs["source_type"] || attrs[:source_type] do
      st when is_binary(st) ->
        if st in Article.known_source_types(), do: st, else: nil

      _ ->
        nil
    end
  end

  defp gate_meta(verdict, assessment) do
    %{
      verdict: to_string(verdict),
      similarity: assessment.score,
      nearest:
        Enum.map(assessment.neighbors, fn n ->
          %{id: n.id, title: n.title, similarity: n.similarity_score}
        end)
    }
  end

  defp format_score(nil), do: "n/a"
  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 3)
  defp format_score(score), do: to_string(score)

  @doc "GET /api/v1/articles or GET /api/v1/projects/:project_id/articles"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # Validate enum-typed filters up front: an unknown value is a client error
    # (400 with the allowed values), not a 404/500 from an Ecto.Enum cast failure.
    with :ok <- ProjectId.validate(params["project_id"]),
         :ok <- validate_enum(params["status"], @valid_statuses, "status"),
         :ok <- validate_enum(params["category"], @valid_categories, "category"),
         {:ok, effective_limit} <- Pagination.validate_limit(params),
         {:ok, match} <- TagMatch.parse(params) do
      opts =
        []
        |> maybe_add_opt(:project_id, string_param(params["project_id"]))
        |> maybe_add_opt(:category, params["category"])
        |> maybe_add_opt(:status, params["status"])
        |> maybe_add_opt(:tags, parse_tags(params["tags"]))
        |> maybe_add_opt(:match, match)
        |> maybe_add_opt(:source_type, string_param(params["source_type"]))
        |> maybe_add_opt(:source_id, string_param(params["source_id"]))
        |> maybe_add_opt(:idempotency_key, string_param(params["idempotency_key"]))
        |> maybe_add_opt(:limit, effective_limit)
        |> maybe_add_opt(:offset, parse_int(params["offset"]))
        # Body-less summary by default; opt into full bodies (byte-budget bounded)
        # with ?include_body=true.
        |> Keyword.put(:include_body, params["include_body"] == "true")
        |> Keyword.merge(Visibility.scope_opts(conn))

      result = Knowledge.list_articles(tenant_id, opts)
      json(conn, ArticleJSON.index(%{articles: result.data, meta: result.meta}))
    else
      # ProjectId.validate/1 returns {:error, :unprocessable_entity, message};
      # delegate it to the FallbackController (422). Matched before the enum
      # clause below because that one also has a 3-element error shape.
      {:error, :unprocessable_entity, _message} = error ->
        error

      {:error, field, allowed} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            status: 400,
            code: "invalid_#{field}",
            message: "Invalid #{field}. Allowed values: #{allowed}."
          }
        })
    end
  end

  # nil/absent (or empty-string, meaning "no filter") is fine; a present value
  # must be one of the enum's values.
  defp validate_enum(nil, _allowed, _field), do: :ok
  defp validate_enum("", _allowed, _field), do: :ok

  defp validate_enum(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, field, Enum.join(allowed, ", ")}
  end

  @doc "GET /api/v1/articles/:id"
  def show(conn, %{"id" => article_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    # `project_id`/`story_id` are advertised by the MCP tool "for attribution" and feed
    # `Knowledge.finalize_article_read/3`'s attribution_context — not reading them here
    # recorded every access on the wiki's most-used endpoint as unattributed. Validated
    # and normalized exactly like every sibling knowledge read: a malformed id is a 422
    # (not a silently discarded attribution), and an EMPTY one is ABSENT — passed raw it
    # takes the explicit-project branch and suppresses the project_id the story would
    # otherwise have supplied.
    opts =
      [api_key_id: conn.assigns.current_api_key.id]
      |> maybe_add_opt(:project_id, string_param(params["project_id"]))
      |> maybe_add_opt(:story_id, string_param(params["story_id"]))
      |> Keyword.merge(Visibility.scope_opts(conn))

    with :ok <- ProjectId.validate(params["project_id"]),
         {:ok, article} <- Knowledge.get_article(tenant_id, article_id, opts) do
      json(
        conn,
        ArticleJSON.show(%{
          article: article,
          links: links_mode(params),
          body_window: BodyWindow.parse(params)
        })
      )
    end
  end

  # #538. Defaults to `:full` so an existing caller sees no change, and an unrecognized
  # value degrades to `:full` rather than 422-ing: this is a presentation knob on a READ,
  # so the cost of a typo should be a fatter response, never a failed knowledge lookup in
  # the middle of an agent's task.
  defp links_mode(params) do
    case params["links"] do
      "none" -> :none
      "count" -> :count
      _ -> :full
    end
  end

  @doc "PATCH /api/v1/articles/:id"
  def update(conn, %{"id" => article_id} = params) do
    api_key = conn.assigns.current_api_key

    # #331 privilege-bypass guard: a caller-supplied `status` on PATCH is a user+
    # capability. `Article.update_changeset/2` CASTS :status with NO
    # `valid_transition?/2` enforcement (the schema trusts it), so an agent PATCHing
    # {"status":"published"} would publish a draft — bypassing the orchestrator-gated
    # publish REVIEW that #331 deliberately keeps at orchestrator+ — and
    # {"status":"superseded"/"archived"} would change lifecycle directly, bypassing
    # the workflow transition guards + the supersede link/confidence flow. On master
    # `update` was user-role, so caller-set status was already a trusted user+
    # capability; gating (not stripping) at user+ reverts exactly the #331-introduced
    # agent exposure without changing user behavior. Agents/orchestrators use the
    # lifecycle endpoints (publish/unpublish/archive). Whole-request reject (not a
    # silent strip) so the caller isn't misled into thinking the status change applied.
    if status_change_forbidden?(params, api_key) do
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: %{
          status: 403,
          code: "status_change_forbidden",
          message:
            "Changing article status is not available on PATCH for your role. Use the " <>
              "lifecycle endpoints: POST /articles/:id/publish (orchestrator+), " <>
              "/unpublish (user+), /archive (agent+)."
        }
      })
    else
      do_update(conn, article_id, params, api_key)
    end
  end

  # A `status` key in the PATCH body is only honoured for user-or-higher (see
  # update/2's guard). role_at_least?/2 is true for :user and :superadmin only, so
  # :agent and :orchestrator are denied.
  defp status_change_forbidden?(params, api_key) do
    Map.has_key?(params, "status") and not Role.role_at_least?(api_key.role, :user)
  end

  defp do_update(conn, article_id, params, api_key) do
    tenant_id = api_key.tenant_id
    # Visibility scope (#163/#331): an agent may only edit an article it can see.
    # Another agent's private/owner memory resolves to :not_found (404), matching
    # the read paths; higher roles pass no scope and can edit anything in-tenant.
    opts = AuditContext.from_conn(conn) ++ Visibility.scope_opts(conn)

    # Validate a caller-supplied project_id (body) before it reaches
    # validate_project_ownership/2, so a non-UUID returns 422, not a CastError 500.
    with :ok <- ProjectId.validate(params["project_id"]) do
      taken =
        params
        |> Map.take([
          "title",
          "body",
          "category",
          "status",
          "tags",
          "metadata",
          "project_id"
        ])
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      # Same write-path binding as create (#163): an agent editing agent-memory
      # metadata may only attribute it to its OWN verified key identity — stamp
      # metadata.agent_id from the key (overriding any spoofed value); an agent
      # with no key identity can't attribute a memory → 403.
      case bind_agent_identity(api_key, taken) do
        {:ok, attrs} ->
          render_update(conn, Knowledge.update_article(tenant_id, article_id, attrs, opts))

        {:error, :no_agent_identity} ->
          conn
          |> put_status(:forbidden)
          |> json(%{
            error: %{
              status: 403,
              code: "agent_identity_required",
              message:
                "This API key has no agent identity; it cannot write an attributed agent memory"
            }
          })
      end
    end
  end

  defp render_update(conn, {:ok, article}),
    do: json(conn, ArticleJSON.update(%{article: article}))

  defp render_update(_conn, {:error, :not_found}), do: {:error, :not_found}
  defp render_update(_conn, {:error, %Ecto.Changeset{} = changeset}), do: {:error, changeset}

  @doc "DELETE /api/v1/articles/:id"
  def delete(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    # Visibility scope (#163/#331): an agent may only archive an article it can
    # see — another agent's private/owner memory 404s.
    opts = AuditContext.from_conn(conn) ++ Visibility.scope_opts(conn)

    case Knowledge.archive_article(tenant_id, article_id, opts) do
      {:ok, article} ->
        json(conn, ArticleJSON.delete(%{article: article}))

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  # A caller opts into staging a draft (instead of the publish-on-create default)
  # via `draft: true` or the equivalent `status: "draft"`.
  defp draft_requested?(params) do
    truthy?(params["draft"]) or params["status"] == "draft"
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # The initial status is set by the server, never trusted from the caller:
  # create yields a published article by default, or a draft when the caller
  # explicitly opted in. Any caller-supplied `status`/`draft`/`publish` is
  # dropped so archived/superseded can't be conjured at create time (those are
  # workflow transitions) and an old `publish:`/`status:"published"` payload is
  # harmless (it just gets the default published outcome).
  defp put_create_status(attrs, true),
    do: attrs |> Map.drop(["publish", "draft"]) |> Map.put("status", "draft")

  defp put_create_status(attrs, false),
    do: attrs |> Map.drop(["publish", "draft"]) |> Map.put("status", "published")

  defp create_response(article) do
    %{article: article}
    |> ArticleJSON.create()
    |> Map.put(:note, create_note(article.status))
  end

  defp create_note(:published),
    do: "Created and published — visible to agents in search/index/context immediately."

  defp create_note(_),
    do:
      "Created as a draft (status: \"draft\"). It is NOT yet visible to agents in " <>
        "search/index/context. Publish it via POST /articles/:id/publish (MCP " <>
        "knowledge_publish, orchestrator role), or omit `draft` to publish on create " <>
        "(no orchestrator role needed for publish-on-create)."

  # Build the dedup (no-op) response. Two cases differ deliberately:
  #
  #   * idempotency_key hit — the caller may NOT possess the existing content
  #     (it matched only on the key, possibly with a different body), and the key
  #     is client-chosen and may be low-entropy. So we return a REFERENCE only
  #     (id/status, no body/title) — a guessable key must not become a way to
  #     read an article the caller didn't author. This also matches #137's ask to
  #     "return a clear already-captured (existing id)".
  #   * identical title+body — the caller already supplied the identical body
  #     (that's what made it a dedup), so echoing the existing row discloses
  #     nothing new; return it in full as before.
  defp dedup_response(existing, attrs, draft?) do
    key = attrs["idempotency_key"] || attrs[:idempotency_key]

    # CONTENT DRIFT (server-derived, never caller-supplied): did the payload we just
    # DISCARDED actually differ from the row we are handing back? A dedup is a no-op,
    # so without this a writer whose content moved believes the new text is stored.
    # loopctl deliberately stays 200-deduplicated rather than 409ing a body mismatch —
    # the fleet's harvest sourcers re-run with stable keys BY DESIGN, so a refusal would
    # break every harvest — and signals the drift instead, leaving the caller to choose
    # knowledge_update. On the title-collision branch both flags are false by
    # construction (that branch requires an identical title AND an identical trimmed
    # body); they are still emitted so the dedup shape is uniform.
    #
    # This adds NO existence/content oracle over #163. Both lookups that can reach
    # here are already visibility-scoped —
    # `Knowledge.get_article_by_idempotency_key/3` and `get_active_article_by_title/3`
    # take the caller's `visibility_agent_id` — so a key or title colliding with
    # ANOTHER agent's private article never produces a dedup at all (it falls through
    # to a generic 422). Every article these flags describe is therefore one the
    # caller may already read in full via GET /articles/:id.
    drift = Knowledge.dedup_drift(existing, attrs)

    if is_binary(key) and existing.idempotency_key == key do
      %{
        data: %{
          id: existing.id,
          status: to_string(existing.status),
          idempotency_key: existing.idempotency_key
        },
        deduplicated: true,
        note: idempotency_dedup_note(existing, drift)
      }
    else
      %{article: existing}
      |> ArticleJSON.create()
      |> Map.put(:deduplicated, true)
      |> Map.put(:note, dedup_note(existing, draft?) <> drift_note(existing, drift))
    end
    |> Map.merge(drift)
  end

  defp idempotency_dedup_note(existing, drift) do
    "An article with this idempotency_key already exists (id #{existing.id}) and was " <>
      "returned unchanged — your title/body were NOT applied (the idempotency_key is the " <>
      "article's identity). To change the existing article, PATCH /articles/:id (role :agent)." <>
      drift_note(existing, drift)
  end

  # Appended only when the discarded payload actually differed. Silence when both flags
  # are false is the point: a re-run that sent identical content has nothing to act on,
  # and a note on every dedup would train callers to ignore this one.
  defp drift_note(_existing, %{content_drift: false, title_drift: false}), do: ""

  # DRIFT IS SYMMETRIC, so the remedy must not be one-directional. The two sides are not
  # distinguishable from the payload alone: the CALLER may have edited, or the STORED row
  # may have moved — a human curated it, or the nightly consolidation retitled it (#765).
  # An earlier wording said only "apply it with knowledge_update", which instructs an
  # UNATTENDED sourcer to overwrite curated edits with whatever its last extraction
  # produced. Read-first comes before the update verb here for that reason.
  defp drift_note(existing, drift) do
    " Your submitted #{drifted_fields(drift)} " <>
      "#{if drift.content_drift and drift.title_drift, do: "differ", else: "differs"} from the " <>
      "stored article, which was NOT changed. Which side moved is not decidable here: the " <>
      "stored article may have been curated or machine-retitled since your last capture, so " <>
      "READ article #{existing.id} (GET /articles/#{existing.id}) before overwriting it. If " <>
      "your version is still the intended one, apply it with knowledge_update on article " <>
      "#{existing.id} (PATCH /articles/#{existing.id}) — re-sending this create will keep " <>
      "being a no-op."
  end

  # The novelty gate's `:duplicate` branch hands back a near-NEIGHBOUR, so `drift_note/2`
  # is wrong there in both directions: its remedy names that id as the thing to PATCH your
  # payload onto — an unattended sourcer following it destroys a third party's (possibly
  # human-curated) body — and its closing "re-sending will keep being a no-op" contradicts
  # the same note's `force: true` offer, since this gate is score-based, not key-based.
  defp neighbor_drift_note(_existing, %{content_drift: false, title_drift: false}), do: ""

  defp neighbor_drift_note(existing, drift) do
    " Your submitted #{drifted_fields(drift)} " <>
      "#{if drift.content_drift and drift.title_drift, do: "differ", else: "differs"} from " <>
      "that article — expected, since it was matched by SIMILARITY and is not a copy of " <>
      "your capture. Do NOT apply this payload to it: READ article #{existing.id} " <>
      "(GET /articles/#{existing.id}) first, then either merge your material into it or " <>
      "re-send with `force: true` to create a separate article."
  end

  defp drifted_fields(%{content_drift: true, title_drift: true}), do: "title and body"
  defp drifted_fields(%{content_drift: true}), do: "body"
  defp drifted_fields(%{title_drift: true}), do: "title"

  # Note for the deduplicated (no-op) case. The article already existed and was
  # returned unchanged, so nothing was created OR published in this call —
  # spelled out per existing status (and the caller's draft/publish intent) so
  # the caller isn't misled by a "Created…"/"published…" message.
  defp dedup_note(%{status: :published}, _draft?),
    do:
      "An identical published article already existed and was returned unchanged (already visible to agents)."

  # Caller explicitly asked to stage a draft and an identical draft already
  # exists — the intent is satisfied, nothing to do.
  defp dedup_note(%{status: :draft}, true),
    do:
      "An identical draft already existed and was returned unchanged. It is a draft " <>
        "(NOT visible to agents); publish it via POST /articles/:id/publish (MCP " <>
        "knowledge_publish, orchestrator role)."

  # Caller asked to publish-on-create, but an identical article already exists as
  # a draft someone staged earlier. Dedup never auto-publishes a staged draft, so
  # the publish intent did not apply — say so honestly with the real remedy (an
  # existing draft is published by orchestrator/user, not the agent).
  defp dedup_note(%{status: :draft}, false),
    do:
      "An identical article already exists as a DRAFT that was staged earlier, so it " <>
        "is NOT visible to agents and your publish-on-create did not change it (dedup " <>
        "never auto-publishes a staged draft). To make it visible, an orchestrator/user " <>
        "must publish it via POST /articles/:id/publish (MCP knowledge_publish), or " <>
        "unpublish/edit it via PATCH /articles/:id."

  defp dedup_note(_existing, _draft?),
    do: "An identical article already existed and was returned unchanged."

  defp maybe_merge_project_id(attrs, nil), do: attrs
  defp maybe_merge_project_id(attrs, project_id), do: Map.put(attrs, "project_id", project_id)

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, []), do: opts
  # An empty-string query param ("?status=") means "no filter", not a value to
  # match (matching status == "" would fail the Ecto.Enum cast).
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Query params are usually strings, but a malformed query like `?project_id[]=x`
  # decodes to a list/map. Treat any non-string value as absent rather than
  # passing it into a where-clause where it would raise (a 500) on cast.
  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: nil

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parsed -> parsed
    end
  end

  # Absent, empty, or a malformed (non-string) `tags` param → no filter.
  defp parse_tags(_), do: nil

  # Strict parse: a trailing-garbage limit/offset (e.g. "100abc") is treated as
  # absent → server default, matching LoopctlWeb.Helpers.Pagination.validate_limit
  # so the *validated* limit and the *applied* limit can never disagree.
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  # nil/absent or a malformed (list/map) limit/offset → no value.
  defp parse_int(_), do: nil
end
