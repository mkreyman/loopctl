defmodule LoopctlWeb.ArticleController do
  @moduledoc """
  Controller for Knowledge Wiki article CRUD operations.

  - `POST /api/v1/articles` -- create tenant-wide article (agent+)
  - `POST /api/v1/projects/:project_id/articles` -- create project-scoped article (agent+)
  - `GET /api/v1/articles` -- list articles with filters (agent+)
  - `GET /api/v1/projects/:project_id/articles` -- list project-scoped articles (agent+)
  - `GET /api/v1/articles/:id` -- get article with preloaded links (agent+)
  - `PATCH /api/v1/articles/:id` -- update article (user+)
  - `DELETE /api/v1/articles/:id` -- archive article / soft delete (user+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  @valid_statuses Article |> Ecto.Enum.values(:status) |> Enum.map(&to_string/1)
  @valid_categories Article |> Ecto.Enum.values(:category) |> Enum.map(&to_string/1)

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user]
       when action in [:update, :delete]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:create, :index, :show]

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
                 "draft-by-default; pass publish: true there.)"
           },
           tags: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
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
                 "change it). Use a HIGH-ENTROPY value (e.g. a content hash): it is a " <>
                 "per-tenant lookup key, not a secret. Distinct from source_type/" <>
                 "source_id, which identify a shared source. Set at create time only " <>
                 "(ignored by PATCH); applies to tenant-scoped articles."
           },
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
        {"Idempotent dedup, returned unchanged with `deduplicated: true`: either an " <>
           "active article with the same title and an identical body exists, OR an " <>
           "article with the same `idempotency_key` exists (in which case a changed " <>
           "title/body is NOT applied). The `note` says which.", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      409 =>
        {"Title taken by an article with different content", "application/json",
         Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
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
        description: "Filter by exact idempotency_key (lag-free existence check)"
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
      "Returns article detail with outgoing and incoming links preloaded. Role: agent+.",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    responses: %{
      200 =>
        {"Article detail", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update article",
    description:
      "**PATCH /api/v1/articles/:id** — updates an existing article in place. Send only " <>
        "the fields to change; supported keys are `title`, `body`, `tags` (replaces the " <>
        "whole array), `category`, `status`, `metadata`, and `project_id`. Partial updates " <>
        "are supported (e.g. body-only to tidy a hub, or tags-only). `tenant_id` is never " <>
        "accepted from the body. Returns the full updated article. A changed `body`/`tags` " <>
        "re-triggers embedding/linking. Role: user+ (distinct from create, which is agent+).",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    request_body:
      {"Update params", "application/json",
       %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 =>
        {"Updated article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Archive article",
    description: "Archives an article (soft delete). Role: user+.",
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
      tenant_id = api_key.tenant_id
      audit_opts = AuditContext.from_conn(conn)

      # If project_id comes from the path (project-scoped route), merge it into
      # attrs, then set the initial status server-side (never trusting the
      # caller's `status`): published by default, draft only when the caller
      # explicitly opted in via draft:true / status:"draft".
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
    opts = audit_opts ++ Visibility.scope_opts(conn)

    if gate? do
      render_proposal(conn, Knowledge.propose_article(tenant_id, attrs, opts), attrs, draft?)
    else
      render_create(conn, Knowledge.create_article(tenant_id, attrs, opts), attrs, draft?)
    end
  end

  # Novelty-gated path: render by verdict. A near-duplicate is NOT created — the
  # caller is pointed at the canonical article. A low-novelty proposal is created as
  # a draft with the near-neighbors surfaced so a reviewer/consumer can merge.
  defp render_proposal(conn, {:ok, %{verdict: :duplicate} = result}, _attrs, _draft?) do
    %{article: existing, assessment: assessment} = result

    conn
    |> put_status(:ok)
    |> json(%{
      data: %{id: existing.id, title: existing.title, status: to_string(existing.status)},
      deduplicated: true,
      gate: gate_meta(:duplicate, assessment),
      note:
        "A near-duplicate already exists (id #{existing.id}, similarity " <>
          "#{format_score(assessment.score)}). Nothing was created — read or update " <>
          "the existing article instead, or pass `force: true` to create anyway."
    })
  end

  defp render_proposal(conn, {:ok, %{verdict: :gated_to_draft} = result}, _attrs, _draft?) do
    %{article: article, assessment: assessment} = result

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
    conn
    |> put_status(:ok)
    |> json(dedup_response(existing, attrs, draft?))
  end

  # :created (novel, or gate fell open) — normal create response.
  defp render_proposal(conn, {:ok, %{article: article}}, _attrs, _draft?) do
    conn
    |> put_status(:created)
    |> json(create_response(article))
  end

  defp render_proposal(conn, error, attrs, draft?),
    do: render_create(conn, error, attrs, draft?)

  # Ungated path (force: true) — the original create semantics.
  defp render_create(conn, {:ok, article}, _attrs, _draft?) do
    conn
    |> put_status(:created)
    |> json(create_response(article))
  end

  defp render_create(conn, {:ok, :deduplicated, existing}, attrs, draft?) do
    conn
    |> put_status(:ok)
    |> json(dedup_response(existing, attrs, draft?))
  end

  defp render_create(conn, {:error, :duplicate_title, existing}, _attrs, _draft?) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        status: 409,
        code: "title_conflict",
        message:
          "An article titled \"#{existing.title}\" already exists in this tenant " <>
            "with different content. Choose a different (more specific) title. " <>
            "(Editing the existing article requires role :user via PATCH /articles/:id.)",
        details: %{existing_article_id: existing.id}
      }
    })
  end

  defp render_create(_conn, {:error, %Ecto.Changeset{} = changeset}, _attrs, _draft?),
    do: {:error, changeset}

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
    with :ok <- validate_enum(params["status"], @valid_statuses, "status"),
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
  def show(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns.current_api_key.id
    opts = Keyword.merge([api_key_id: api_key_id], Visibility.scope_opts(conn))

    case Knowledge.get_article(tenant_id, article_id, opts) do
      {:ok, article} ->
        json(conn, ArticleJSON.show(%{article: article}))

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "PATCH /api/v1/articles/:id"
  def update(conn, %{"id" => article_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    attrs =
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

    case Knowledge.update_article(tenant_id, article_id, attrs, audit_opts) do
      {:ok, article} ->
        json(conn, ArticleJSON.update(%{article: article}))

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "DELETE /api/v1/articles/:id"
  def delete(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case Knowledge.archive_article(tenant_id, article_id, audit_opts) do
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

    if is_binary(key) and existing.idempotency_key == key do
      %{
        data: %{
          id: existing.id,
          status: to_string(existing.status),
          idempotency_key: existing.idempotency_key
        },
        deduplicated: true,
        note: idempotency_dedup_note(existing)
      }
    else
      %{article: existing}
      |> ArticleJSON.create()
      |> Map.put(:deduplicated, true)
      |> Map.put(:note, dedup_note(existing, draft?))
    end
  end

  defp idempotency_dedup_note(existing) do
    "An article with this idempotency_key already exists (id #{existing.id}) and was " <>
      "returned unchanged — your title/body were NOT applied (the idempotency_key is the " <>
      "article's identity). To change the existing article, PATCH /articles/:id (role :user)."
  end

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
