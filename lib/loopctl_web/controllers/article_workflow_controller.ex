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
  alias LoopctlWeb.ArticleJSON
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:drafts, :publish]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user] when action in [:unpublish, :archive, :bulk_publish, :bulk_delete]

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
    summary: "Bulk delete (archive) articles",
    description:
      "Soft-deletes (archives) articles **partial-success** style. Provide **exactly one** " <>
        "selector (supplying more than one is a 400): `article_ids` (explicit list), " <>
        "`source_type` + `source_id` (every active article from that source — clean dedup " <>
        "cleanup; not confirm-gated, can be large), or `tag` + `confirm: true` (every active " <>
        "article carrying the tag — high blast radius, so `confirm: true` is required). " <>
        "Honors soft-delete: rows move to `archived`, not dropped. Each id gets a per-id " <>
        "`outcome` (`archived`; `skipped` with `already_archived`/`not_archivable_from_superseded`; " <>
        "`not_found`; `errored`). `meta.count` = number archived; `meta.counts`/`meta.results` " <>
        "give the breakdown. A 200 does not imply everything archived — inspect `meta.counts`. " <>
        "Bounded to 5000 per call; a `source_type`/`tag` selector matching more than 5000 active " <>
        "articles returns 400 (narrow the selector). An `article_ids` request with zero matches " <>
        "still returns 200 (per-id `not_found`); a `source`/`tag` selector matching nothing " <>
        "returns 400. Role: user+.",
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
      limit: [in: :query, type: :integer, description: "Max results (default 20, max 100)"],
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
        data: Enum.map(result.published, &ArticleJSON.article_data/1),
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

  @doc "POST /api/v1/knowledge/bulk-delete"
  def bulk_delete(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    with {:ok, ids} <- resolve_bulk_delete_ids(tenant_id, params),
         {:ok, result} <- Knowledge.bulk_archive(tenant_id, ids, audit_opts) do
      json(conn, %{
        data: Enum.map(result.archived, &ArticleJSON.article_data/1),
        meta: %{
          # `count` = number actually archived.
          count: result.counts.archived,
          counts: result.counts,
          results: result.results
        }
      })
    end
  end

  # Resolve the bulk-delete selector to a concrete id list. EXACTLY ONE selector
  # must be supplied (enforced — not first-match-wins — so a stray second
  # selector can't silently win and, e.g., bypass the by-tag confirm gate):
  #   - article_ids: [..]                  (explicit list)
  #   - source_type + source_id            (every active article from that source)
  #   - tag + confirm: true                (every active article carrying the tag;
  #                                         confirm required — high blast radius)
  defp resolve_bulk_delete_ids(tenant_id, params) do
    # `source_type`/`source_id` count as one selector ("source"); supplying only
    # one half still selects "source" so the pairing error fires (not the generic
    # one).
    present =
      [
        {:article_ids, params["article_ids"]},
        {:source, params["source_type"] || params["source_id"]},
        {:tag, params["tag"]}
      ]
      |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
      |> Enum.map(&elem(&1, 0))

    case present do
      [:article_ids] ->
        resolve_ids_selector(params["article_ids"])

      [:source] ->
        resolve_source_selector(tenant_id, params)

      [:tag] ->
        resolve_tag_selector(tenant_id, params)

      [] ->
        {:error, :bad_request, selector_help()}

      _ ->
        {:error, :bad_request, "Provide exactly ONE selector (got several). " <> selector_help()}
    end
  end

  defp selector_help do
    "Selectors: article_ids (list), source_type + source_id, or tag + confirm: true."
  end

  defp resolve_ids_selector(ids) when is_list(ids), do: {:ok, ids}
  defp resolve_ids_selector(_), do: {:error, :bad_request, "article_ids must be a JSON array."}

  defp resolve_source_selector(tenant_id, %{"source_type" => type, "source_id" => src})
       when is_binary(type) and is_binary(src) do
    archivable_ids_or_error(tenant_id, source_type: type, source_id: src)
  end

  defp resolve_source_selector(_tenant_id, _params) do
    {:error, :bad_request, "source_type and source_id must be provided together."}
  end

  defp resolve_tag_selector(tenant_id, %{"tag" => tag} = params) when is_binary(tag) do
    if truthy?(params["confirm"]) do
      archivable_ids_or_error(tenant_id, tags: [tag])
    else
      {:error, :bad_request,
       "Deleting by tag archives every active article carrying it — pass confirm: true to proceed."}
    end
  end

  defp resolve_tag_selector(_tenant_id, _params) do
    {:error, :bad_request, "tag must be a string."}
  end

  defp archivable_ids_or_error(tenant_id, filters) do
    case Knowledge.list_archivable_ids(tenant_id, filters) do
      {:ok, []} ->
        {:error, :bad_request, "No active articles match the selector."}

      {:ok, ids} ->
        {:ok, ids}

      {:error, :too_many} ->
        {:error, :bad_request, "Selector matches too many articles; narrow it."}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  @doc "GET /api/v1/knowledge/drafts"
  def drafts(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

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

  # --- Private helpers ---

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
end
