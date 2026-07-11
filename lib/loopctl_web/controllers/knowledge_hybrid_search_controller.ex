defmodule LoopctlWeb.KnowledgeHybridSearchController do
  @moduledoc """
  Controller for the single hybrid knowledge retrieval entrypoint (US-31.4).

  - `POST /api/v1/knowledge/hybrid_search` -- resolve a topic against the hybrid
    resolver (curated-first, retrieval fallback) with provenance (agent+)

  This is a thin transport layer over `Loopctl.Knowledge.hybrid_search/3`
  (US-31.2): it runs the combined keyword+semantic search over the FULL ranked
  pool, decides whether a genuinely-answering CURATED source wins, and returns
  the resulting page plus a provenance verdict:

  - `provenance: "curated"` -- a governed/curated article actually answers the
    query and is guaranteed FIRST in `data`; `meta.curated_article_id` points at
    it. Trust it as the canonical answer.
  - `provenance: "retrieved"` -- no curated source clears the bar, so the answer
    is the best semantic/keyword match. `meta.curated_article_id` is `null`.

  `meta.confidence` is the winning candidate's absolute score for that same
  provenance class. All the underlying combined-search meta (search_mode,
  fallback, fallback_reason, total_count, etc.) is preserved.

  POST (not GET, unlike `GET /knowledge/search`) is a deliberate divergence: the
  richer request carries a JSON body. Additive only -- existing `knowledge_*`
  endpoints are unchanged.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.Helpers.ProjectId
  alias LoopctlWeb.Helpers.TagMatch
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_categories Ecto.Enum.values(Article, :category)

  operation(:hybrid_search,
    summary: "Hybrid knowledge retrieval with provenance",
    description:
      "Single hybrid retrieval entrypoint (US-31.4). Runs combined keyword+semantic " <>
        "search over the FULL ranked pool, then decides whether a genuinely-answering " <>
        "CURATED source wins. Returns the page plus a `meta.provenance` verdict: " <>
        "`curated` (a governed article actually answers — trust it as canonical, it is " <>
        "guaranteed first in `data`, and `meta.curated_article_id` points at it) or " <>
        "`retrieved` (best semantic/keyword match; `meta.curated_article_id` is null). " <>
        "`meta.confidence` is the winning candidate's absolute score for that provenance " <>
        "class. All underlying combined-search meta (search_mode, fallback, " <>
        "fallback_reason, total_count) is preserved. Prefer this over " <>
        "`GET /knowledge/search` when you want a single trustworthy answer with its " <>
        "provenance, not a ranked list to triage yourself. POST (vs the GET search " <>
        "endpoint) carries the richer JSON body. Role: agent+.",
    request_body:
      {"Hybrid search request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:query],
         properties: %{
           query: %OpenApiSpex.Schema{
             type: :string,
             description: "The topic/question to resolve (max 500 characters)."
           },
           project_id: %OpenApiSpex.Schema{
             type: :string,
             description: "Optional: scope to a project UUID."
           },
           category: %OpenApiSpex.Schema{
             type: :string,
             description: "Optional: filter by category."
           },
           tags: %OpenApiSpex.Schema{
             type: :string,
             description: "Optional: comma-separated tags to filter by."
           },
           match: %OpenApiSpex.Schema{
             type: :string,
             enum: ["any", "all"],
             description: "Optional: tag match mode — any (default, OR) or all (AND)."
           },
           limit: %OpenApiSpex.Schema{
             type: :integer,
             description: "Optional: max results to return (default 10)."
           },
           offset: %OpenApiSpex.Schema{
             type: :integer,
             description: "Optional: results to skip for pagination (default 0)."
           }
         }
       }},
    responses: %{
      200 =>
        {"Hybrid search results", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description:
                 "Matching articles with scores and snippets. When provenance is " <>
                   "`curated`, the winning curated article is first."
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 provenance: %OpenApiSpex.Schema{
                   type: :string,
                   enum: ["curated", "retrieved"],
                   description:
                     "curated = a governed article answers (canonical, first in data); " <>
                       "retrieved = best semantic/keyword match."
                 },
                 confidence: %OpenApiSpex.Schema{
                   type: :number,
                   description: "Winning candidate's absolute score for its provenance class."
                 },
                 curated_article_id: %OpenApiSpex.Schema{
                   type: :string,
                   nullable: true,
                   description:
                     "The winning curated article id when provenance=curated, else null."
                 },
                 limit: %OpenApiSpex.Schema{type: :integer},
                 offset: %OpenApiSpex.Schema{type: :integer},
                 search_mode: %OpenApiSpex.Schema{type: :string},
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 fallback: %OpenApiSpex.Schema{type: :boolean},
                 fallback_reason: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/knowledge/hybrid_search"
  def hybrid_search(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns.current_api_key.id

    with {:ok, query} <- resolve_query(params),
         {:ok, base_opts} <- build_opts(params) do
      opts =
        base_opts
        |> Keyword.put(:api_key_id, api_key_id)
        |> Keyword.merge(Visibility.scope_opts(conn))

      case Knowledge.hybrid_search(tenant_id, query, opts) do
        {:ok, result} ->
          json(conn, LoopctlWeb.KnowledgeHybridSearchJSON.hybrid_search(result))

        {:error, :empty_query} ->
          {:error, :bad_request, "Field 'query' is required and cannot be empty"}

        # Defensive against the published `hybrid_search/3` contract: `search_combined`
        # can return `{:error, :invalid_weights}` from `validate_weights`. `build_opts/1`
        # never puts keyword/semantic weights today, so this is currently unreachable —
        # but handling it explicitly keeps a future weight-tuning param from degrading
        # into a CaseClauseError 500 instead of a clean 400.
        {:error, :invalid_weights} ->
          {:error, :bad_request,
           "Invalid keyword/semantic weights: each must be between 0 and 1 and sum to 1"}

        {:error, :bad_request, msg} ->
          {:error, :bad_request, msg}
      end
    end
  end

  # `query` is always required for hybrid retrieval (there is no query-less
  # enumeration mode — that is what `GET /knowledge/search` list mode is for).
  defp resolve_query(params) do
    trimmed = params |> Map.get("query") |> trim_query()

    cond do
      trimmed == "" ->
        {:error, :bad_request, "Field 'query' is required and cannot be empty"}

      String.length(trimmed) > 500 ->
        {:error, :bad_request, "Field 'query' exceeds maximum length of 500 characters"}

      true ->
        {:ok, trimmed}
    end
  end

  defp trim_query(q) when is_binary(q), do: String.trim(q)
  defp trim_query(_), do: ""

  defp build_opts(params) do
    with :ok <- ProjectId.validate(params["project_id"]),
         {:ok, category} <- validate_category(params["category"]),
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

  defp validate_category(nil), do: {:ok, nil}
  defp validate_category(""), do: {:ok, nil}

  defp validate_category(category) when is_binary(category) do
    atom = String.to_existing_atom(category)
    if atom in @valid_categories, do: {:ok, atom}, else: invalid_category()
  rescue
    ArgumentError -> invalid_category()
  end

  defp validate_category(_), do: invalid_category()

  defp invalid_category do
    valid = Enum.map_join(@valid_categories, ", ", &to_string/1)
    {:error, :bad_request, "Invalid category. Valid categories: #{valid}"}
  end

  defp maybe_add_tags(opts, nil), do: opts
  defp maybe_add_tags(opts, ""), do: opts

  defp maybe_add_tags(opts, tags_str) when is_binary(tags_str) do
    tags =
      tags_str
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if tags == [], do: opts, else: [{:tags, tags} | opts]
  end

  defp maybe_add_tags(opts, _), do: opts

  defp maybe_add_limit(opts, nil), do: [{:limit, 10} | opts]

  defp maybe_add_limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:limit, clamp_limit(int)} | opts]
      _ -> [{:limit, 10} | opts]
    end
  end

  defp maybe_add_limit(opts, value) when is_integer(value) do
    [{:limit, clamp_limit(value)} | opts]
  end

  defp maybe_add_limit(opts, _), do: [{:limit, 10} | opts]

  defp clamp_limit(value), do: value |> max(1) |> min(Knowledge.max_page_size())

  @max_offset 1_000_000

  defp maybe_add_offset(opts, nil), do: [{:offset, 0} | opts]

  defp maybe_add_offset(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:offset, clamp_offset(int)} | opts]
      _ -> [{:offset, 0} | opts]
    end
  end

  defp maybe_add_offset(opts, value) when is_integer(value) do
    [{:offset, clamp_offset(value)} | opts]
  end

  defp maybe_add_offset(opts, _), do: [{:offset, 0} | opts]

  defp clamp_offset(value), do: value |> max(0) |> min(@max_offset)
end
