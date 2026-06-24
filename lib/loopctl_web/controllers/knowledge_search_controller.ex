defmodule LoopctlWeb.KnowledgeSearchController do
  @moduledoc """
  Controller for the unified knowledge search endpoint.

  - `GET /api/v1/knowledge/search` -- search articles by keyword, semantic, or combined mode (agent+)

  Supports three search modes:

  - `keyword` -- full-text search using PostgreSQL ts_rank_cd
  - `semantic` -- vector similarity search via pgvector (embedding generated on-the-fly)
  - `combined` (default) -- weighted merge of keyword + semantic scores with graceful fallback

  Returns article metadata with a score and snippet (max 300 chars). Never returns the full body.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.Helpers.Pagination
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_modes ~w(keyword semantic combined)
  @valid_categories Ecto.Enum.values(Article, :category)

  operation(:search,
    summary: "Search knowledge articles",
    description:
      "Unified search endpoint supporting keyword, semantic, and combined modes. " <>
        "Returns article metadata with scores and snippets (max 300 chars). " <>
        "No full body is returned. Combined mode is the default and falls back to " <>
        "keyword-only if embedding generation fails. " <>
        "`q` is optional when `tags` and/or `category` are supplied: in that " <>
        "**list mode** the endpoint returns the complete filtered set (no relevance " <>
        "ranking, score 0.0, no snippet) ordered by recency, fully reachable via " <>
        "`offset`/`limit` pagination over `meta.total_count`. " <>
        "**`meta.total_count` is mode-dependent** — `meta.total_count_scope` says " <>
        "exactly what it counts: `keyword_matches` (articles matching the " <>
        "stop-word-filtered Postgres tsquery — a pure stop-word query like 'the' " <>
        "matches almost nothing), `ranked_corpus` (semantic ranks all EMBEDDED " <>
        "published articles, so the count is the size of that embedded set — not a " <>
        "match count, and <= the total published count), `merged_candidates` " <>
        "(combined mode: the deduped UNION of a keyword and a semantic sub-search, " <>
        "each capped at 100, so up to ~200), or `filtered_set` " <>
        "(list mode: the complete filtered set). Do NOT use a relevance-mode " <>
        "`total_count` to size the corpus — use list mode or `GET /knowledge/stats`. " <>
        "Role: agent+.",
    parameters: [
      q: [
        in: :query,
        type: :string,
        description:
          "Search query (max 500 characters). Optional when tags/category are supplied.",
        required: false
      ],
      mode: [
        in: :query,
        type: :string,
        description: "Search mode: keyword, semantic, or combined (default: combined)",
        required: false
      ],
      project_id: [
        in: :query,
        type: :string,
        description: "Filter by project UUID",
        required: false
      ],
      category: [
        in: :query,
        type: :string,
        description: "Filter by category",
        required: false
      ],
      tags: [
        in: :query,
        type: :string,
        description: "Comma-separated tags to filter by (match mode set by `match`)",
        required: false
      ],
      match: [
        in: :query,
        type: :string,
        description: "Tag match mode: any (default, OR) or all (AND — carries every listed tag)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description:
          "Max results to return (default 10). The cap is mode-dependent and a limit " <>
            "above it is rejected with 400 — never silently clamped. **List mode** (no " <>
            "`q`, just `tags`/`category`) is exhaustive enumeration: max 1000, paginate " <>
            "the complete filtered set via `offset`. **Relevance modes** (keyword / " <>
            "semantic / combined) return a ranked top-N: max 100.",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Results to skip for pagination (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Search results", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Matching articles with scores and snippets"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 total_count_scope: %OpenApiSpex.Schema{
                   type: :string,
                   enum: ["keyword_matches", "ranked_corpus", "merged_candidates", "filtered_set"],
                   description: "What total_count counts for this mode"
                 },
                 search_mode: %OpenApiSpex.Schema{
                   type: :string,
                   enum: ["keyword", "list", "semantic_only", "combined", "keyword_only"],
                   description:
                     "The mode that actually ran (keyword_only = combined degraded to keyword)"
                 },
                 limit: %OpenApiSpex.Schema{type: :integer},
                 offset: %OpenApiSpex.Schema{type: :integer}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Service unavailable", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             error: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 status: %OpenApiSpex.Schema{type: :integer},
                 message: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }}
    }
  )

  @doc "GET /api/v1/knowledge/search"
  def search(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns.current_api_key.id

    with {:ok, query_spec} <- resolve_query(params),
         {:ok, mode} <- validate_mode(params),
         :ok <- validate_search_limit(params, query_spec),
         {:ok, base_opts} <- build_opts(params) do
      opts =
        base_opts
        |> Keyword.put(:api_key_id, api_key_id)
        |> Keyword.merge(Visibility.scope_opts(conn))

      case execute_search(tenant_id, query_spec, mode, opts) do
        {:ok, result} ->
          json(conn, LoopctlWeb.KnowledgeSearchJSON.search(result, mode))

        {:error, :embedding_unavailable} ->
          conn
          |> put_status(503)
          |> json(%{error: %{status: 503, message: "Embedding service unavailable"}})

        {:error, :empty_query} ->
          {:error, :bad_request, "Query parameter 'q' is required and cannot be empty"}

        {:error, :bad_request, msg} ->
          {:error, :bad_request, msg}
      end
    end
  end

  # Resolves the query parameter into either a relevance search (`{:search, q}`)
  # or a query-less enumeration (`:list`). `q` is optional only when a `tags`
  # and/or `category` filter is supplied, otherwise it is required.
  defp resolve_query(params) do
    trimmed = params |> Map.get("q") |> trim_query()

    cond do
      trimmed != "" and String.length(trimmed) > 500 ->
        {:error, :bad_request, "Query parameter 'q' exceeds maximum length of 500 characters"}

      trimmed != "" ->
        {:ok, {:search, trimmed}}

      filter_present?(params) ->
        {:ok, :list}

      true ->
        {:error, :bad_request,
         "Query parameter 'q' is required (or supply 'tags' and/or 'category' " <>
           "to enumerate the full filtered set)"}
    end
  end

  defp trim_query(q) when is_binary(q), do: String.trim(q)
  defp trim_query(_), do: ""

  defp filter_present?(params) do
    present?(params["tags"]) or present?(params["category"])
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp validate_mode(%{"mode" => mode}) when mode in @valid_modes, do: {:ok, mode}

  defp validate_mode(%{"mode" => _invalid}) do
    {:error, :bad_request, "Invalid search mode. Valid modes: keyword, semantic, combined"}
  end

  defp validate_mode(_), do: {:ok, "combined"}

  defp build_opts(params) do
    with {:ok, category} <- validate_category(params["category"]),
         {:ok, match} <- TagMatch.parse(params) do
      opts =
        []
        |> maybe_add_opt(:project_id, params["project_id"])
        |> maybe_add_opt(:category, category)
        |> maybe_add_tags(params["tags"])
        |> Keyword.put(:match, match)
        |> maybe_add_limit(params["limit"])
        |> maybe_add_offset(params["offset"])

      {:ok, opts}
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: [{key, value} | opts]

  # Reject an unknown OR non-category-but-existing atom (e.g. "published") with a
  # 400, mirroring the index controller. Without this, list mode would either
  # crash on a CastError or silently drop the filter and return the whole catalog.
  defp validate_category(nil), do: {:ok, nil}
  defp validate_category(""), do: {:ok, nil}

  defp validate_category(category) when is_binary(category) do
    atom = String.to_existing_atom(category)
    if atom in @valid_categories, do: {:ok, atom}, else: invalid_category()
  rescue
    ArgumentError -> invalid_category()
  end

  defp invalid_category do
    valid = Enum.map_join(@valid_categories, ", ", &to_string/1)
    {:error, :bad_request, "Invalid category. Valid categories: #{valid}"}
  end

  defp maybe_add_tags(opts, nil), do: opts
  defp maybe_add_tags(opts, ""), do: opts

  defp maybe_add_tags(opts, tags_str) do
    tags =
      tags_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tags == [], do: opts, else: [{:tags, tags} | opts]
  end

  # List mode is exhaustive enumeration (cap: the shared max page size); the
  # relevance modes return a ranked top-N (a much smaller cap). Validating the
  # requested `limit` against the mode-appropriate cap — and 400-ing over it —
  # keeps `meta.limit` honest in every mode (a relevance request for limit=200
  # is rejected, never silently clamped to the ranked-pool size).
  defp validate_search_limit(params, :list),
    do: Pagination.validate_limit(params, Knowledge.max_page_size())

  defp validate_search_limit(params, {:search, _q}) do
    case Pagination.validate_limit(params, Knowledge.max_relevance_page_size()) do
      :ok ->
        :ok

      {:error, :bad_request, _} ->
        {:error, :bad_request,
         "limit exceeds the relevance-mode maximum of #{Knowledge.max_relevance_page_size()}; " <>
           "for exhaustive enumeration drop 'q' to use list mode (max #{Knowledge.max_page_size()})"}
    end
  end

  # `limit` is honored up to the relevant cap; over-cap requests are rejected
  # with 400 by `validate_search_limit/2` (in `search/2`) rather than silently
  # clamped here. The `min/2` is a safety net for direct/list callers.
  defp maybe_add_limit(opts, nil), do: [{:limit, 10} | opts]

  defp maybe_add_limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:limit, int |> max(1) |> min(Knowledge.max_page_size())} | opts]
      _ -> [{:limit, 10} | opts]
    end
  end

  defp maybe_add_limit(opts, value) when is_integer(value) do
    [{:limit, value |> max(1) |> min(Knowledge.max_page_size())} | opts]
  end

  defp maybe_add_limit(opts, _), do: [{:limit, 10} | opts]

  defp maybe_add_offset(opts, nil), do: [{:offset, 0} | opts]

  defp maybe_add_offset(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:offset, max(int, 0)} | opts]
      _ -> [{:offset, 0} | opts]
    end
  end

  defp maybe_add_offset(opts, value) when is_integer(value) do
    [{:offset, max(value, 0)} | opts]
  end

  defp maybe_add_offset(opts, _), do: [{:offset, 0} | opts]

  # List mode: query-less enumeration of the filtered set, regardless of `mode`.
  defp execute_search(tenant_id, :list, _mode, opts) do
    Knowledge.list_filtered(tenant_id, opts)
  end

  defp execute_search(tenant_id, {:search, q}, "keyword", opts) do
    Knowledge.search_keyword(tenant_id, q, opts)
  end

  defp execute_search(tenant_id, {:search, q}, "semantic", opts) do
    case Knowledge.generate_embedding(q) do
      {:ok, embedding} -> Knowledge.search_semantic(tenant_id, embedding, opts)
      {:error, _} -> {:error, :embedding_unavailable}
    end
  end

  defp execute_search(tenant_id, {:search, q}, "combined", opts) do
    Knowledge.search_combined(tenant_id, q, opts)
  end
end
