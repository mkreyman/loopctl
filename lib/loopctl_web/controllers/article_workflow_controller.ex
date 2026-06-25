defmodule LoopctlWeb.ArticleWorkflowController do
  @moduledoc """
  Controller for article publish workflow operations.

  - `POST /api/v1/articles/:id/publish` -- publish a draft article (orchestrator+)
  - `POST /api/v1/articles/:id/unpublish` -- unpublish a published article (user+)
  - `POST /api/v1/articles/:id/archive` -- archive an article (user+)
  - `POST /api/v1/knowledge/bulk-publish` -- bulk publish drafts (user+)
  - `POST /api/v1/knowledge/bulk-delete` -- bulk archive/soft-delete (user+)
  - `GET /api/v1/knowledge/drafts` -- list draft articles (orchestrator+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.BulkOps
  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.Helpers.Pagination

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:drafts, :publish]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user]
       when action in [:unpublish, :archive, :bulk_publish, :bulk_unpublish, :bulk_delete]

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
      "Transitions article to archived status. " <>
        "Valid from draft or published. Returns 422 if superseded. Role: user+.",
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
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results per page (default 20, max 1000). A limit above the max is " <>
            "rejected with 400 — not silently clamped."
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
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, article} <-
           Knowledge.archive_article_workflow(tenant_id, article_id, audit_opts) do
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
         {:ok, ids} <- BulkOps.resolve_selector(tenant_id, selector),
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

    with :ok <- Pagination.validate_limit(params) do
      opts =
        []
        |> maybe_add_opt(:project_id, params["project_id"])
        |> maybe_add_opt(:limit, parse_int(params["limit"]))
        |> maybe_add_opt(:offset, parse_int(params["offset"]))

      result = Knowledge.list_drafts(tenant_id, opts)

      json(conn, %{
        data: Enum.map(result.data, &ArticleJSON.article_data/1),
        meta: result.meta
      })
    end
  end

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
