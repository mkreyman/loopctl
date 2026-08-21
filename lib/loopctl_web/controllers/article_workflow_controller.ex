defmodule LoopctlWeb.ArticleWorkflowController do
  @moduledoc """
  Controller for article publish workflow operations.

  - `POST /api/v1/articles/:id/publish` -- publish a draft article (orchestrator+)
  - `POST /api/v1/articles/:id/unpublish` -- unpublish a published article (user+)
  - `POST /api/v1/articles/:id/archive` -- archive an article (agent+)
  - `POST /api/v1/knowledge/bulk-publish` -- bulk publish drafts (user+)
  - `POST /api/v1/knowledge/bulk-delete` -- bulk archive/soft-delete (user+)
  - `GET /api/v1/knowledge/drafts` -- list draft articles (orchestrator+)
  - `POST /api/v1/knowledge/conflicts` -- assert a conflict the system never flagged (agent+)

  Role note (#331): single-article `archive` and `resolve_conflict` (all
  dispositions, incl. supersede/merge) are agent+ KB-content curation —
  NON-DESTRUCTIVE + audited (the row survives; supersede retires via a reversible
  link; merge produces a DRAFT). Non-destructive is not reversible: `:archived` is
  TERMINAL (no `{:archived, _}` transition, no unarchive function), so the only way
  back is a `user+` PATCH — an unattended writer that needs an undo must use
  `unpublish` (#605/#606). The SET-BASED bulk ops (`bulk_delete`, incl. the
  irreversible HARD-delete path, `bulk_publish`, `bulk_unpublish`) stay
  `user`-gated: high blast radius AND irreversible.

  Recording a verdict stays agent+ in every disposition; what an agent cannot do
  ALONE is drive the unattended RETIREMENT that a `supersede` at confidence "high"
  triggers. The role gate is the plug; the confidence a `supersede` is recorded at
  is granted from that same role in `Loopctl.Knowledge.annotate_conflict/3`, never
  taken from the request body. A `merge` retires nothing, so it is not capped.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.BulkOps
  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:drafts, :publish]

  # Set-based bulk ops (high blast radius; bulk_delete includes an irreversible
  # HARD-delete path) and unpublish stay user-gated.
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user]
       when action in [:unpublish, :bulk_publish, :bulk_unpublish, :bulk_delete]

  # Single-article archive and conflict resolution are agent+ KB curation (#331):
  # non-destructive + audited (NOT reversible — `:archived` is terminal).
  # archive is visibility-scoped in-action.
  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:archive, :conflicts, :resolve_conflict, :assert_conflict]

  tags(["Knowledge Wiki"])

  operation(:publish,
    summary: "Publish article",
    description:
      "Transitions article from draft to published. " <>
        "Returns 422 if the transition is invalid. Role: orchestrator+.",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    responses: %{
      200 =>
        {"Published article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:unpublish,
    summary: "Unpublish article",
    description:
      "Transitions article from published back to draft. " <>
        "Returns 422 if the transition is invalid. Role: user+.",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    responses: %{
      200 =>
        {"Unpublished article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:archive,
    summary: "Archive article",
    description:
      "Transitions article to archived status (soft delete — the row is retained and " <>
        "the act is audited, but `archived` is TERMINAL: it has no outbound transition " <>
        "and there is no unarchive endpoint, so restoring one takes a user+ PATCH with " <>
        "an explicit status. Use `unpublish` when you need a retraction you can undo). " <>
        "Valid from draft or published. Returns 422 if superseded. Role: agent+ " <>
        "(an agent may only archive an article it can see — another agent's " <>
        "private/owner memory 404s).",
    parameters: [id: [in: :path, type: :string, description: "Article UUID"]],
    responses: %{
      200 =>
        {"Archived article", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Invalid transition", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:bulk_publish,
    summary: "Bulk publish articles",
    description:
      "Publishes draft articles **partial-success** style. Every valid draft is " <>
        "published; each other id gets a per-id `outcome` instead of failing the whole " <>
        "call: `published`; `skipped` (with `reason` `already_published` — idempotent — " <>
        "or `not_publishable_from_archived`/`not_publishable_from_superseded`); " <>
        "`not_found` (no such article in this tenant, incl. malformed ids); or " <>
        "`errored` (`reason` `publish_failed`). **A 200 does NOT mean everything " <>
        "published** — inspect `meta.counts`: a request of all already-published or " <>
        "not-found ids still returns 200 with `count: 0`. Duplicate ids are " <>
        "de-duplicated. There is **no 100-id cap** (auto-chunked server-side, each " <>
        "chunk its own transaction; a failing chunk is retried row-by-row so one bad " <>
        "row never sinks the rest), but a single request is bounded to 5000 ids " <>
        "(400 above that). `meta.count` = number actually published; `meta.counts` has " <>
        "requested/published/skipped/not_found/errored; `meta.results` is the per-id " <>
        "breakdown in request order. Role: user+.",
    request_body:
      {"Bulk publish params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:article_ids],
         properties: %{
           article_ids: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string, format: :uuid}
           }
         }
       }},
    responses: %{
      200 =>
        {"Bulk publish result (partial success; see meta.results / meta.counts)",
         "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      400 => {"Bad request (empty article_ids)", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:bulk_delete,
    summary: "Bulk archive / hard-delete articles (set-based, US-27.12)",
    description:
      "SET-BASED bulk cleanup. Provide **exactly one** selector (supplying more than one is a " <>
        "400): `article_ids` (explicit list), `source_type` + `source_id` (every active article " <>
        "from that source), or `tag` + `confirm: true` (every active article carrying the tag — " <>
        "high blast radius, so `confirm: true` is required). All selectors are bounded to 5000 " <>
        "active matches (over that → 400). Tenant-scoped: foreign ids never match.\n\n" <>
        "**Default (soft) path** — archives the matched active set in ONE `update_all` + one " <>
        "audit event. Idempotent (re-archiving is a no-op). Returns `{data: {affected: N}, " <>
        "meta: {op: \"archive\", set_based: true, affected: N}}`.\n\n" <>
        "**`dry_run: true`** — previews `{would_affect: N}` and mutates nothing. For the " <>
        "irreversible delete path it also returns `meta.token` (a single-use, TTL-bounded " <>
        "frozen-set token) when N is within the bound, or `meta.oversized: true` + " <>
        "`meta.confirm_hash` for the re-confirm-on-drift path over the bound.\n\n" <>
        "**`hard: true`** — irreversible HARD delete (FK-correct: article_links pre-deleted both " <>
        "directions, access-events cascade). Requires a `token` from a prior dry-run, OR (for an " <>
        "oversized selector) the original selector plus the dry-run `confirm_hash` (refused on " <>
        "drift). Role: user+ (all destructive ops).",
    request_body:
      {"Bulk delete selector", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           article_ids: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string, format: :uuid}
           },
           source_type: %OpenApiSpex.Schema{type: :string},
           source_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           tag: %OpenApiSpex.Schema{type: :string},
           confirm: %OpenApiSpex.Schema{
             type: :boolean,
             description: "Required (true) when deleting by tag."
           },
           dry_run: %OpenApiSpex.Schema{
             type: :boolean,
             description: "Preview only; mutates nothing. Mints a delete token for the hard path."
           },
           hard: %OpenApiSpex.Schema{
             type: :boolean,
             description: "Irreversible HARD delete (requires a token or confirm_hash)."
           },
           token: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             description: "Frozen-set token from a prior dry_run; required for hard delete."
           },
           confirm_hash: %OpenApiSpex.Schema{
             type: :string,
             description: "Echoed from an oversized dry_run; re-confirm-on-drift for hard delete."
           }
         }
       }},
    responses: %{
      200 =>
        {"Bulk delete result (partial success; see meta.results / meta.counts)",
         "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      400 =>
        {"Bad request (no/ambiguous selector, tag without confirm, empty match, or over cap)",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:drafts,
    summary: "List draft articles",
    description:
      "Lists draft articles ordered by inserted_at desc. " <>
        "Includes source_type and source_id for review queue visibility. Role: orchestrator+.",
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        description: "Filter by project: UUID, slug, or repo directory name"
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results per page (default 20, max 1000). A limit above the max is " <>
            "clamped to the maximum — never rejected — so pagination stays complete."
      ],
      offset: [in: :query, type: :integer, description: "Records to skip"]
    ],
    responses: %{
      200 =>
        {"Drafts list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:conflicts,
    summary: "List potential-conflict article pairs",
    description:
      "Lists `:potential_conflict` pairs — published articles flagged 'too similar to " <>
        "comfortably coexist' by the auto-linker / nightly lint sweep, highest-overlap " <>
        "first. The KB only flags; the caller decides whether each is a redundancy to " <>
        "merge or a real contradiction to reconcile. Role: agent+.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results per page (default 50, max 1000). A limit above the max is " <>
            "clamped to the maximum — never rejected — so pagination stays complete."
      ],
      offset: [in: :query, type: :integer, description: "Records to skip"]
    ],
    responses: %{
      200 =>
        {"Conflicts list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:assert_conflict,
    summary: "Assert a conflict pair the system never flagged",
    description:
      "Opens a `:potential_conflict` pair for two articles the auto-linker did NOT flag, " <>
        "so a DELIBERATE correction is reachable: a session that just wrote an article " <>
        "refuting another has a pair minutes old (the nightly linker has not run) which may " <>
        "never be lexically similar enough to be flagged at all. The pair then appears in " <>
        "GET /api/v1/knowledge/conflicts with `origin: \"asserted\"` and the claim " <>
        "attached, and in both articles' `potential_conflicts`. Role: agent+. " <>
        "`evidence` is REQUIRED — an assertion with no argument is noise on the one queue " <>
        "a reviewer reads. " <>
        "**This opens the pair; it does not decide it.** An assertion does NOT suppress " <>
        "either article from curated answers (that still requires a system flag), and the " <>
        "asserting principal may NOT record the pair's verdict — " <>
        "POST /knowledge/conflicts/resolve returns 409 `self_asserted_conflict` to it. The " <>
        "pair is manufacturable by construction (you named both ids), so judging it is " <>
        "someone else's call, exactly as the confidence cap already separates recording a " <>
        "supersede from authorizing one. " <>
        "Idempotent per pair: an existing flag is returned (`created: false`) rather than " <>
        "duplicated, and an assertion never overwrites a system flag's provenance.",
    request_body:
      {"Assertion", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:source_article_id, :target_article_id, :evidence],
         properties: %{
           source_article_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           target_article_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           classification: %OpenApiSpex.Schema{
             type: :string,
             enum: ["redundant", "complementary", "contradictory"]
           },
           evidence: %OpenApiSpex.Schema{
             type: :string,
             description:
               "REQUIRED. Why these two conflict — ideally the ground truth that settles " <>
                 "it (commit, file:line, URL, observed behaviour). This is what a reviewer " <>
                 "judges the pair on; it travels with the pair in the conflict queue."
           },
           proposed_authoritative_article_id: %OpenApiSpex.Schema{
             type: :string,
             format: :uuid,
             description:
               "Optional: which of the two you believe should win. Recorded as your CLAIM " <>
                 "on the queue row — it is not a verdict and applies nothing."
           }
         }
       }},
    responses: %{
      201 =>
        {"Pair asserted (`data.created` is false when an equivalent flag already existed)",
         "application/json", %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 =>
        {"One or both articles not found in this tenant", "application/json",
         Schemas.ErrorResponse},
      422 =>
        {"Validation error (missing/blank `evidence`, the same article twice, or a member " <>
           "the caller cannot see)", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:resolve_conflict,
    summary: "Record a verdict on a potential-conflict pair",
    description:
      "Record how a potential-conflict pair should be resolved. `dismiss` (false positive) " <>
        "takes effect immediately; `supersede` (with authoritative_article_id) is applied by " <>
        "the nightly executor at confidence \"high\" — it creates a supersedes link and " <>
        "retires the loser (reversible, audited); `merge` is recorded for the later LLM step " <>
        "(it produces a new DRAFT, never auto-published). " <>
        "The KB never re-judges — it acts on your verdict. Last-write-wins per pair. Only " <>
        "pairs the system flagged (GET /knowledge/conflicts) may be resolved; an unknown pair " <>
        "returns 422. All dispositions are agent+ KB-content curation (#331): they are " <>
        "non-destructive + audited, and the privileged nightly executor is what actually " <>
        "applies supersede/merge. " <>
        "**On a `supersede`, `confidence` is granted, not accepted.** Only an orchestrator+ " <>
        "key can record `high` there, the value that authorizes the executor to RETIRE an " <>
        "article unattended; an agent-role request asking for `high` is recorded at " <>
        "`medium`, the response says so in `data.requested_confidence` and `note`, and the " <>
        "pair stays in GET /knowledge/conflicts so an orchestrator+ key can re-record it. " <>
        "`merge` retires nothing (it synthesizes a new draft, sources preserved) and is " <>
        "never capped, but a `high` merge is NOT unattended-free: the executor synthesizes on " <>
        "the tenant's own paid model key and POSTs both bodies to the provider. A `high` " <>
        "supersede OR merge therefore REQUIRES `evidence` (422 without it) — every verdict " <>
        "the executor applies with nobody in the loop must carry the reason it was reached. " <>
        "A supersede/merge recorded BELOW `high` is closed as dismissed by the next nightly " <>
        "run (both articles retained); it is not held for review.",
    request_body:
      {"Resolution", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:source_article_id, :target_article_id, :disposition],
         properties: %{
           source_article_id: %OpenApiSpex.Schema{type: :string},
           target_article_id: %OpenApiSpex.Schema{type: :string},
           disposition: %OpenApiSpex.Schema{
             type: :string,
             enum: ["dismiss", "supersede", "merge"]
           },
           authoritative_article_id: %OpenApiSpex.Schema{type: :string},
           classification: %OpenApiSpex.Schema{
             type: :string,
             enum: ["redundant", "complementary", "contradictory"]
           },
           evidence: %OpenApiSpex.Schema{
             type: :string,
             description:
               "Why this verdict was reached. REQUIRED for a supersede OR merge recorded " <>
                 "at confidence `high` — those are the verdicts the nightly executor " <>
                 "applies with nobody in the loop."
           },
           confidence: %OpenApiSpex.Schema{
             type: :string,
             enum: ["high", "medium", "low"],
             description:
               "Requested confidence. On a `supersede` it is capped server-side by the " <>
                 "recording key's role: `high` is recorded only for an orchestrator+ key. " <>
                 "When capped, the response carries the requested value in " <>
                 "`data.requested_confidence`. `merge` is never capped."
           }
         }
       }},
    responses: %{
      201 =>
        {"Recorded (see `data.confidence` for what was GRANTED, and " <>
           "`data.requested_confidence` when it was capped)", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      422 =>
        {"Validation error (including a `high` supersede/merge with no `evidence`), or no " <>
           "system-flagged potential_conflict for the pair", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:bulk_unpublish,
    summary: "Bulk unpublish articles",
    description:
      "Unpublishes (published → draft) articles **partial-success** style — the " <>
        "mirror of bulk-publish, for cleanup passes. Every currently-published id is " <>
        "moved back to draft; each other id gets a per-id `outcome`: `unpublished`; " <>
        "`skipped` (with `reason` `already_draft` — idempotent — or " <>
        "`not_unpublishable_from_archived`/`not_unpublishable_from_superseded`); " <>
        "`not_found`; or `errored` (`reason` `unpublish_failed`). **A 200 does NOT " <>
        "mean everything unpublished** — inspect `meta.counts`. Duplicate ids " <>
        "de-duplicated; auto-chunked server-side (each chunk its own transaction, " <>
        "failing chunk retried row-by-row); bounded to 5000 ids (400 above). " <>
        "`meta.count` = number actually unpublished; `meta.counts` has " <>
        "requested/unpublished/skipped/not_found/errored; `meta.results` is the per-id " <>
        "breakdown in request order. `data` is the body-less summaries of the affected " <>
        "articles. Role: user+.",
    request_body:
      {"Bulk unpublish params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:article_ids],
         properties: %{
           article_ids: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string, format: :uuid}
           }
         }
       }},
    responses: %{
      200 =>
        {"Bulk unpublish result (partial success; see meta.results / meta.counts)",
         "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      400 => {"Bad request (empty article_ids)", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # --- Actions ---

  @doc "POST /api/v1/articles/:id/publish"
  def publish(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, article} <- Knowledge.publish_article(tenant_id, article_id, audit_opts) do
      json(conn, ArticleJSON.update(%{article: article}))
    end
  end

  @doc "POST /api/v1/articles/:id/unpublish"
  def unpublish(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, article} <- Knowledge.unpublish_article(tenant_id, article_id, audit_opts) do
      json(conn, ArticleJSON.update(%{article: article}))
    end
  end

  @doc "POST /api/v1/articles/:id/archive"
  def archive(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    # Visibility scope (#163/#331): an agent may only archive an article it can
    # see — another agent's private/owner memory 404s (matching reads).
    opts = AuditContext.from_conn(conn) ++ Visibility.scope_opts(conn)

    with {:ok, article} <-
           Knowledge.archive_article_workflow(tenant_id, article_id, opts) do
      json(conn, ArticleJSON.update(%{article: article}))
    end
  end

  @doc "POST /api/v1/knowledge/bulk-publish"
  def bulk_publish(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)
    article_ids = params["article_ids"] || []

    with {:ok, result} <- Knowledge.bulk_publish(tenant_id, article_ids, audit_opts) do
      json(conn, %{
        # Body-less summaries: the affected set as confirmation; the actionable
        # per-id detail is in meta.results (consistent with bulk-unpublish, #158).
        data: Enum.map(result.published, &ArticleJSON.article_summary/1),
        meta: %{
          # `count` kept for backward compatibility = number actually published.
          count: result.counts.published,
          counts: result.counts,
          # Per-id breakdown so a partial run is actionable (published / skipped /
          # not_found / errored), in request order.
          results: result.results
        }
      })
    end
  end

  @doc "POST /api/v1/knowledge/bulk-unpublish"
  def bulk_unpublish(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)
    article_ids = params["article_ids"] || []

    with {:ok, result} <- Knowledge.bulk_unpublish(tenant_id, article_ids, audit_opts) do
      json(conn, %{
        # Body-less summaries: the affected set as confirmation; the actionable
        # per-id detail is in meta.results.
        data: Enum.map(result.unpublished, &ArticleJSON.article_summary/1),
        meta: %{
          # `count` = number actually unpublished (partial-success: inspect counts).
          count: result.counts.unpublished,
          counts: result.counts,
          results: result.results
        }
      })
    end
  end

  @doc "POST /api/v1/knowledge/bulk-delete"
  def bulk_delete(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    cond do
      truthy?(params["dry_run"]) ->
        bulk_delete_dry_run(conn, tenant_id, params, audit_opts)

      truthy?(params["hard"]) ->
        bulk_delete_hard(conn, tenant_id, params, audit_opts)

      true ->
        bulk_delete_soft(conn, tenant_id, params, audit_opts)
    end
  end

  # Soft path (default, backward-compatible): set-based ARCHIVE (US-27.12), not the
  # per-row bulk_archive — one update_all + one audit event so AC-27.12.1/.8 hold
  # for the by-tag/source/ids archive. Idempotent (re-archiving is a no-op).
  defp bulk_delete_soft(conn, tenant_id, params, audit_opts) do
    with {:ok, selector} <- bulk_delete_selector(params),
         {:ok, %{affected: affected, resolved_count: resolved}} <-
           BulkOps.archive(tenant_id, selector, audit_opts) do
      json(conn, %{
        data: %{affected: affected},
        # Backward-compatible SUPERSET: the original shipped MCP client reads
        # meta.counts.{requested,archived,skipped,not_found,errored} and
        # meta.results — keep those populated so existing consumers keep working,
        # while ADDING the new set-based affected/set_based/op fields. archived =
        # affected; skipped = resolved - affected (rows already archived/inactive);
        # not_found/errored are 0 for a set-based archive (foreign/inactive ids
        # simply don't resolve, they aren't a per-id failure). results is [] —
        # the set-based op has no per-id breakdown.
        meta: %{
          op: "archive",
          set_based: true,
          affected: affected,
          count: affected,
          counts: %{
            requested: resolved,
            archived: affected,
            skipped: resolved - affected,
            not_found: 0,
            errored: 0
          },
          results: []
        }
      })
    else
      {:error, :too_many} ->
        {:error, :bad_request, "Selector matches too many articles; narrow it."}

      other ->
        other
    end
  end

  # Dry-run: previews would_affect and mutates nothing.
  # If hard: true, also mints a frozen-set token (when within the bound) or a
  # confirm_hash for the oversized re-confirm-on-drift path (AC-27.12.9).
  # Otherwise (soft/archive path), returns only would_affect without a token.
  defp bulk_delete_dry_run(conn, tenant_id, params, audit_opts) do
    # Preview the op the caller actually intends: :delete (with a frozen-set token
    # / confirm_hash) only when hard: true; otherwise the soft/archive path, which
    # mints NO delete token. meta.op makes the response self-describing (BUG2).
    op = if truthy?(params["hard"]), do: :delete, else: :archive

    with {:ok, selector} <- bulk_delete_selector(params),
         {:ok, preview} <- BulkOps.preview(tenant_id, op, selector, audit_opts) do
      meta =
        %{dry_run: true, op: to_string(op)}
        |> maybe_put(:token, preview[:token])
        |> maybe_put(:oversized, preview[:oversized])
        |> maybe_put(:confirm_hash, oversized_confirm_hash(tenant_id, preview))

      json(conn, %{data: %{would_affect: preview.would_affect}, meta: meta})
    else
      {:error, :too_many} ->
        {:error, :bad_request, "Selector matches too many articles; narrow it."}

      other ->
        other
    end
  end

  # Hard delete (irreversible). Requires `hard: true` AND either a frozen `token`
  # from a prior dry-run, OR (for an oversized selector that got no token) the
  # original selector plus the `confirm_hash` echoed from the dry-run — re-resolved
  # and refused on drift.
  defp bulk_delete_hard(conn, tenant_id, params, audit_opts) do
    case params["token"] do
      token when is_binary(token) ->
        bulk_delete_with_token(conn, tenant_id, token, audit_opts)

      _ ->
        bulk_delete_reconfirm(conn, tenant_id, params, audit_opts)
    end
  end

  defp bulk_delete_with_token(conn, tenant_id, token, audit_opts) do
    case BulkOps.delete_with_token(tenant_id, token, audit_opts) do
      {:ok, %{affected: affected}} ->
        json(conn, %{
          data: %{affected: affected},
          meta: %{op: "delete", set_based: true, affected: affected}
        })

      {:error, :invalid_token} ->
        {:error, :bad_request,
         "Invalid, expired, or already-used delete token. Re-run the dry-run to mint a fresh one."}

      other ->
        other
    end
  end

  # Re-confirm-on-drift: oversized selector (no frozen token). This path is NOT
  # single-use (an oversized selector mints no frozen-set token) — its safety comes
  # entirely from a live drift check, not from token consumption:
  #
  #   1. The server RE-RESOLVES the selector right now (BulkOps.resolve_selector),
  #      getting the CURRENT matching, tenant-scoped, active id-set.
  #   2. It recomputes confirm_hash over that live set and compares it to the hash
  #      the dry-run echoed to the client.
  #   3. If the id-set GREW (a new row started matching the tag/source after the
  #      dry-run) OR shrank, the hash differs → 400 "drift", nothing is deleted.
  #
  # This is exactly the harmful case a replay could otherwise cause: it is
  # IMPOSSIBLE to sweep newly-matching rows the operator never previewed, because
  # any such new row changes the hash and is refused. A byte-identical replay (same
  # selector, same hash, set unchanged) re-deletes an already-gone set → affected 0,
  # harmless. So "not single-use" does not mean "replayable into damage": the drift
  # check, not a nonce, is the guarantee. (The minted reconfirm nonce is a
  # belt-and-suspenders replay marker; the load-bearing protection is the hash.)
  defp bulk_delete_reconfirm(conn, tenant_id, params, audit_opts) do
    confirm_hash = params["confirm_hash"]

    with true <- is_binary(confirm_hash) || :missing_confirm_hash,
         {:ok, selector} <- bulk_delete_selector(params),
         {:ok, ids} <- BulkOps.resolve_delete_selector(tenant_id, selector),
         ^confirm_hash <- BulkOps.confirm_hash(tenant_id, ids),
         {:ok, %{affected: affected}} <- BulkOps.delete(tenant_id, ids, audit_opts) do
      json(conn, %{
        data: %{affected: affected},
        meta: %{op: "delete", set_based: true, affected: affected}
      })
    else
      :missing_confirm_hash ->
        {:error, :bad_request,
         "Hard delete requires a `token` (from a dry-run) or, for an oversized selector, " <>
           "the original selector plus the `confirm_hash` echoed by the dry-run."}

      {:error, :too_many} ->
        {:error, :bad_request, "Selector matches too many articles; narrow it."}

      {:error, :bad_request, _msg} = err ->
        err

      # Hash mismatch (drift): when ^confirm_hash fails, the computed hash is the mismatch value
      mismatch when is_binary(mismatch) ->
        {:error, :bad_request,
         "Selector drifted since the dry-run (confirm_hash mismatch). Re-run the dry-run."}

      # Any other error (unexpected shapes, not drift) surfaces as-is
      other_error ->
        other_error
    end
  end

  # Translate the wire params into a BulkOps selector tuple. EXACTLY ONE selector
  # (same enforcement as the soft per-row path); tag still requires confirm: true.
  defp bulk_delete_selector(params) do
    present =
      [
        {:ids, params["article_ids"]},
        {:source, params["source_type"] || params["source_id"]},
        {:tag, params["tag"]}
      ]
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Enum.map(&elem(&1, 0))

    case present do
      [:ids] ->
        ids_selector(params["article_ids"])

      [:source] ->
        source_selector(params)

      [:tag] ->
        tag_selector(params)

      [] ->
        {:error, :bad_request, selector_help()}

      _ ->
        {:error, :bad_request, "Provide exactly ONE selector (got several). " <> selector_help()}
    end
  end

  defp ids_selector(ids) when is_list(ids), do: {:ok, {:ids, ids}}
  defp ids_selector(_), do: {:error, :bad_request, "article_ids must be a JSON array."}

  # Thread BOTH source_type and source_id into the selector so the combined
  # filter behaves as the shipped contract documents: a source_id whose
  # source_type differs must NOT match. Both are required together (the pairing
  # check below is what the half-specified test exercises).
  defp source_selector(%{"source_id" => src, "source_type" => stype})
       when is_binary(src) and is_binary(stype) do
    {:ok, {:source, %{source_id: src, source_type: stype}}}
  end

  defp source_selector(_),
    do: {:error, :bad_request, "source_type and source_id must be provided together."}

  defp tag_selector(%{"tag" => tag} = params) when is_binary(tag) do
    if truthy?(params["confirm"]) do
      {:ok, {:tag, tag}}
    else
      {:error, :bad_request,
       "Deleting by tag affects every active article carrying it — pass confirm: true to proceed."}
    end
  end

  defp tag_selector(_), do: {:error, :bad_request, "tag must be a string."}

  defp oversized_confirm_hash(tenant_id, %{oversized: true, frozen_ids: ids}) when is_list(ids) do
    # frozen_ids is internal to preview; recompute the hash the client echoes back
    # on the oversized re-confirm path. (We expose only its hash, not the id-set.)
    BulkOps.confirm_hash(tenant_id, ids)
  end

  defp oversized_confirm_hash(_tenant_id, _preview), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp selector_help do
    "Selectors: article_ids (list), source_type + source_id, or tag + confirm: true."
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  @doc "GET /api/v1/knowledge/drafts"
  def drafts(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, effective_limit} <- Pagination.validate_limit(params) do
      opts =
        []
        |> maybe_add_opt(:project_id, params["project_id"])
        |> maybe_add_opt(:limit, effective_limit)
        |> maybe_add_opt(:offset, parse_int(params["offset"]))

      result = Knowledge.list_drafts(tenant_id, opts)

      json(conn, %{
        data: Enum.map(result.data, &ArticleJSON.article_data/1),
        meta: result.meta
      })
    end
  end

  @doc "GET /api/v1/knowledge/conflicts"
  def conflicts(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, effective_limit} <- Pagination.validate_limit(params) do
      opts =
        []
        |> maybe_add_opt(:limit, effective_limit)
        |> maybe_add_opt(:offset, parse_int(params["offset"]))
        # Visibility scope (#331): an agent must not even see a conflict pair whose
        # member is another agent's private/owner memory — parity with resolve.
        |> Keyword.merge(Visibility.scope_opts(conn))

      result = Knowledge.list_potential_conflicts(tenant_id, opts)

      json(conn, result)
    end
  end

  @doc "POST /api/v1/knowledge/conflicts"
  def assert_conflict(conn, params) do
    api_key = conn.assigns.current_api_key

    attrs = %{
      "source_article_id" => params["source_article_id"],
      "target_article_id" => params["target_article_id"],
      "classification" => params["classification"],
      "evidence" => params["evidence"],
      "proposed_authoritative_article_id" => params["proposed_authoritative_article_id"]
    }

    opts =
      AuditContext.from_conn(conn) ++
        Visibility.scope_opts(conn) ++
        [actor_principal: actor_principal(api_key)]

    case Knowledge.assert_conflict(api_key.tenant_id, attrs, opts) do
      {:ok, link, outcome} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            link_id: link.id,
            source_article_id: link.source_article_id,
            target_article_id: link.target_article_id,
            origin: if(link.metadata["asserted"] == true, do: "asserted", else: "system"),
            created: outcome == :created
          },
          note: assertion_note(link, outcome)
        })

      {:error, :evidence_required} ->
        {:error, :unprocessable_entity,
         "evidence is required: an asserted conflict carries no similarity score, so the " <>
           "argument IS the evidence a reviewer judges the pair on."}

      {:error, :same_article} ->
        {:error, :unprocessable_entity,
         "source_article_id and target_article_id must name two different articles."}

      {:error, :missing_article_id} ->
        {:error, :unprocessable_entity,
         "source_article_id and target_article_id are both required."}

      # An article the caller cannot SEE is answered as not-found, deliberately identical
      # to an article that does not exist (parity with resolve_conflict): an agent must not
      # be able to probe which private article ids exist by comparing the two answers.
      # A member that genuinely does not exist falls through to the changeset below, which
      # names the offending field.
      {:error, :article_not_visible} ->
        {:error, :not_found}

      # Server-derived; a caller cannot cause this by any request it can make. It means the
      # authenticated key resolved to no principal at all, and an assertion nobody can be
      # held apart from is worse than no assertion.
      {:error, :unattributed_assertion} ->
        {:error, :unprocessable_entity,
         "This key resolves to no principal, so an assertion recorded under it could not " <>
           "be held apart from the verdict that judges it. Use a key with an agent identity."}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp assertion_note(_link, :existing),
    do:
      "This pair was already flagged — nothing was created and the existing flag's " <>
        "provenance is unchanged. It is in GET /api/v1/knowledge/conflicts."

  defp assertion_note(_link, :created),
    do:
      "Asserted. The pair is now in GET /api/v1/knowledge/conflicts (origin \"asserted\") " <>
        "and in both articles' potential_conflicts. Neither article is suppressed from " <>
        "curated answers — an assertion is a claim, not a system finding — and YOU cannot " <>
        "record its verdict (409 self_asserted_conflict); another key judges it."

  # The principal an assertion is attributed to, and the one a later verdict is held apart
  # from. `agent_id` first because that is the identity the KB already treats as an actor
  # (visibility scoping, and the heat index's `coalesce(agent_id, api_key_id)` reader); the
  # key id is the fallback for roles that carry no agent. Under v2 per-dispatch ephemeral
  # keys the key id alone would count DISPATCHES rather than actors, which is why the agent
  # id has to win when both exist.
  defp actor_principal(api_key) do
    case api_key.agent_id do
      nil -> to_string(api_key.id)
      agent_id -> to_string(agent_id)
    end
  end

  @doc "POST /api/v1/knowledge/conflicts/resolve"
  def resolve_conflict(conn, params) do
    # #331: recording a verdict on a potential-conflict pair — dismiss, supersede,
    # OR merge — is agent+ KB-content curation. All dispositions are non-destructive
    # + audited: supersede retires the loser via a supersedes link (only at
    # confidence "high", by the privileged nightly executor), and merge produces a
    # new DRAFT (never auto-published). The fabrication guard still stands — only
    # a pair the system flagged as a `:potential_conflict` may be resolved (422
    # otherwise) — so opening the disposition doesn't let an agent retire an
    # arbitrary pair. The agent role gate is the static RequireRole plug above.
    do_resolve_conflict(conn, conn.assigns.current_api_key.tenant_id, params)
  end

  defp do_resolve_conflict(conn, tenant_id, params) do
    # Visibility scope (#331): an agent may only resolve a pair whose BOTH members
    # it can see — annotate_conflict/3 refuses an invisible member as :no_potential_conflict
    # (422), matching the update/delete/archive paths. Higher roles pass no scope.
    #
    # `:actor_role` comes from the AUTHENTICATED key, never from params — it caps the
    # confidence the verdict is recorded at, and `confidence: "high"` is what lets the
    # nightly executor retire an article with nobody watching. `Plugs.Impersonate` already
    # rewrites `current_api_key.role` to the effective role, so this reads the role the
    # request actually acts with (same source `Visibility.scope_opts/1` uses).
    opts =
      AuditContext.from_conn(conn) ++
        Visibility.scope_opts(conn) ++
        [
          actor_role: conn.assigns.current_api_key.role,
          # #730: identifies the RECORDER, so a verdict on an ASSERTED pair can be refused
          # when it comes from the principal that asserted it. Inert on a system-flagged
          # pair, which carries no asserter.
          actor_principal: actor_principal(conn.assigns.current_api_key)
        ]

    attrs = %{
      "source_article_id" => params["source_article_id"],
      "target_article_id" => params["target_article_id"],
      "disposition" => params["disposition"],
      "authoritative_article_id" => params["authoritative_article_id"],
      "classification" => params["classification"],
      "evidence" => params["evidence"],
      "confidence" => params["confidence"]
    }

    case Knowledge.annotate_conflict(tenant_id, attrs, opts) do
      {:ok, resolution} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: resolution.id,
            disposition: to_string(resolution.disposition),
            confidence: to_string(resolution.confidence),
            # Present (non-null) only when the server granted LESS than was asked for, so
            # a caller learns the cap from the response instead of from a verdict that
            # never applies.
            requested_confidence:
              resolution.requested_confidence && to_string(resolution.requested_confidence),
            executed: not is_nil(resolution.executed_at)
          },
          note: resolution_note(resolution)
        })

      # kb-02: no system-flagged :potential_conflict link exists for this pair — the
      # caller may not fabricate a verdict on an arbitrary pair.
      {:error, :no_potential_conflict} ->
        {:error, :unprocessable_entity,
         "No potential-conflict link exists for this article pair. Only pairs the system " <>
           "flagged as potential conflicts (see GET /api/v1/knowledge/conflicts) can be resolved."}

      # #730 — rendered by the FallbackController as 409 self_asserted_conflict.
      {:error, :self_asserted_conflict} = error ->
        error

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # `:dismiss` is complete on record and ignores confidence entirely, so it is answered
  # before the cap note — a capped dismiss changed nothing about the outcome.
  defp resolution_note(%{disposition: :dismiss}),
    do: "Dismissed as a false positive — the pair is removed from the conflict queue."

  # The cap is reported to the caller rather than left to be inferred from a verdict that
  # never applies: confidence is granted from the RECORDING ROLE, not accepted from the
  # request, because "high" is what authorizes the unattended retirement. The note states
  # where the pair goes next — a capped verdict is NOT auto-applied and NOT auto-dismissed,
  # and its pair stays in GET /knowledge/conflicts precisely so it can be re-recorded.
  defp resolution_note(%{disposition: :supersede, requested_confidence: asked, confidence: got})
       when not is_nil(asked),
       do:
         "Recorded at confidence #{got}, NOT the #{asked} requested: only an orchestrator+ " <>
           "key may authorize the unattended supersede that high confidence triggers. " <>
           "Nothing is auto-applied and nothing is auto-dismissed — the pair stays in " <>
           "GET /knowledge/conflicts until an orchestrator+ key records it at high confidence."

  defp resolution_note(%{disposition: :supersede, confidence: :high}),
    do:
      "Recorded. The nightly executor will supersede the loser (create a supersedes link " <>
        "and retire it) — reversible and audited."

  defp resolution_note(%{disposition: :merge, confidence: :high}),
    do:
      "Recorded. The nightly executor will synthesize a MERGED DRAFT from both articles " <>
        "using this tenant's own model key — both sources stay published, the draft is " <>
        "never auto-published, and it inherits the more restrictive of the two sources' " <>
        "visibility."

  # The twins below. NOT "left for review": a supersede/merge deliberately recorded below
  # high is closed as DISMISSED by the next nightly run and the pair leaves the queue, so a
  # note promising review would send the caller back to a surface the verdict is no longer
  # on. Re-recording at high confidence is the only route to applying it.
  defp resolution_note(%{disposition: disposition}) when disposition in [:supersede, :merge],
    do:
      "Recorded, but NOT auto-applied: #{disposition} executes only at confidence \"high\". " <>
        "The next nightly run CLOSES it as dismissed (both articles retained) and the pair " <>
        "leaves GET /knowledge/conflicts — re-annotate at high confidence to apply it."

  # --- Private helpers ---

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  # Strict parse: trailing garbage (e.g. "100abc") → absent, matching
  # LoopctlWeb.Helpers.Pagination.validate_limit so validated and applied limits agree.
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
end
