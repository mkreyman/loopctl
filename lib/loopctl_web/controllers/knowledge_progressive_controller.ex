defmodule LoopctlWeb.KnowledgeProgressiveController do
  @moduledoc """
  Controller for progressive-disclosure knowledge retrieval (US-31.3, surfaced by
  US-31.4).

  - `GET /api/v1/knowledge/progressive_index` -- a bounded, topic-scoped list of
    compact stubs (id/title/category/summary, NO bodies), capped at top-K (agent+)
  - `GET /api/v1/knowledge/progressive/:id` -- drill into one stub, returning the
    full article body, scope-enforced (agent+)

  This is the "index then drill" half of the hybrid interface: an agent first
  pulls a cheap, capped index of what's relevant to a topic, then opens only the
  article(s) it needs — keeping context small. Thin transport over
  `Loopctl.Knowledge.progressive_index/3` and `Loopctl.Knowledge.progressive_drill/3`.
  Additive only — existing `knowledge_*` endpoints are unchanged.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @valid_categories Ecto.Enum.values(Article, :category)

  # The published description and the ENFORCED bound read the same value, so tuning the window
  # cannot silently make the docs promise history the server no longer scans.
  @heat_default_window_days Knowledge.heat_default_window_days()
  @heat_max_window_days Knowledge.heat_max_window_days()

  operation(:index,
    summary: "Progressive-disclosure index",
    description:
      "Returns a bounded, topic-scoped list of compact stubs " <>
        "(id/title/category/summary — never bodies), capped at top-K, with " <>
        "curated sources preferred and hub-linked neighbors enriched in. Use it to " <>
        "cheaply survey what's relevant to a topic, then drill into only the " <>
        "article(s) you need via GET /knowledge/progressive/:id. `meta.truncated` " <>
        "is true when the candidate pool exceeded top-K. Role: agent+.",
    parameters: [
      topic: [
        in: :query,
        type: :string,
        description: "The topic to index (max 500 characters). Required.",
        required: true
      ],
      category: [
        in: :query,
        type: :string,
        description: "Optional: filter by category.",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Optional: top-K override (clamped to the configured cap).",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Progressive index stubs", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Compact stubs: id, title, category, summary (no bodies)."
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 top_k: %OpenApiSpex.Schema{type: :integer},
                 candidate_count: %OpenApiSpex.Schema{type: :integer},
                 truncated: %OpenApiSpex.Schema{type: :boolean}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/progressive_index"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, category} <- validate_category(params["category"]) do
      opts =
        []
        |> maybe_add_opt(:category, category)
        |> maybe_add_limit(params["limit"])
        |> Keyword.merge(Visibility.scope_opts(conn))

      case Knowledge.progressive_index(tenant_id, coerce_topic(params["topic"]), opts) do
        {:ok, result} ->
          json(conn, LoopctlWeb.KnowledgeProgressiveJSON.index(result))

        {:error, :empty_query} ->
          {:error, :bad_request, "Query parameter 'topic' is required and cannot be empty"}

        {:error, :bad_request, msg} ->
          {:error, :bad_request, msg}
      end
    end
  end

  operation(:heat_index,
    summary: "Heat-ranked topic index (no query)",
    description:
      "A bounded, top-K-capped stub list of the corpus (tenant articles plus published " <>
        "system canonicals) ordered by HEAT — the number of DISTINCT READERS (the agent " <>
        "behind the calling key, or the key itself when it has no agent) that read each " <>
        "article's BODY directly. Repeat reads by one reader count once. " <>
        "Only caller-chosen fetches are counted " <>
        "(`meta.counted_access_types`); list-shaped ranker output (a search hit, a context " <>
        "pack) is one row per RESULT, not a read, so it adds no heat. Neither does drilling " <>
        "a listed article of ANY scope (GET /knowledge/progressive/:id) — tenant-owned or " <>
        "system canonical, that read is recorded under its own access type, so this index " <>
        "never feeds the ranking that surfaced the article; a plain knowledge_get of the " <>
        "same id does count, and resolves canonicals too. `char_budget`/`chars` " <>
        "are BYTES of the encoded stub array (framing included), exclusive of `meta`. " <>
        "Takes NO query, " <>
        "which is the " <>
        "point: every other retrieval route starts from one, so they all miss the same way " <>
        "on a paraphrase or on material that is topically central but lexically dissimilar. " <>
        "This route's failures are uncorrelated with embedding similarity.\n\n" <>
        "Stubs only (id/title/category/heat/one-line summary) — never a body — so it is cheap " <>
        "enough to keep in a cached prefix rather than fetch per turn. The response states " <>
        "which tool to call with which parameter to read a listed article, and states " <>
        "`meta.truncated` when more articles were hot than the cap returned. " <>
        "Visibility-scoped: an agent key never sees another agent's private/owner memory, " <>
        "not even as a stub. Role: agent+.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description: "Top-K stubs, clamped to 1..100. Defaults to the progressive top-K."
      ],
      category: [
        in: :query,
        type: :string,
        description: "Restrict the index to a single category."
      ],
      since: [
        in: :query,
        type: :string,
        description:
          "ISO-8601 timestamp. Count only accesses at/after it. Omitted means the last " <>
            "#{@heat_default_window_days} days, and a lookback longer than " <>
            "#{@heat_max_window_days} days is CLAMPED to that ceiling — both bound the " <>
            "request-path aggregate over an ever-growing read history. A future timestamp " <>
            "is clamped to the start of today. An explicit timestamp is otherwise used " <>
            "VERBATIM; only the omitted default and the ceiling are anchored at the start " <>
            "of today, which is what keeps a default refresh byte-identical. Pass an older " <>
            "timestamp to widen the window deliberately; the effective window is echoed " <>
            "as `meta.heat_window`."
      ]
    ],
    responses: %{
      200 =>
        {"Heat-ranked stubs", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
             meta: %OpenApiSpex.Schema{type: :object}
           }
         }},
      400 => {"Invalid parameter", "application/json", Schemas.ErrorResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/heat_index"
  def heat_index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, category} <- validate_category(params["category"]),
         {:ok, since} <- validate_since(params["since"]) do
      opts =
        []
        |> maybe_add_opt(:category, category)
        |> maybe_add_opt(:since, since)
        |> maybe_add_limit(params["limit"])
        |> Keyword.merge(Visibility.scope_opts(conn))

      {:ok, result} = Knowledge.heat_index(tenant_id, opts)
      json(conn, LoopctlWeb.KnowledgeProgressiveJSON.heat_index(result))
    end
  end

  # A malformed timestamp is a 400, never a silent all-time fallback: silently widening the
  # window a caller explicitly narrowed would hand back more than it asked for and look correct.
  defp validate_since(nil), do: {:ok, nil}
  defp validate_since(""), do: {:ok, nil}

  defp validate_since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> invalid_since()
    end
  end

  # `?since[]=x` makes Plug parse the param as a list — without this clause that is a
  # FunctionClauseError -> 500, the same transport-boundary failure `coerce_topic/1` and
  # `validate_category/1` already guard.
  defp validate_since(_), do: invalid_since()

  defp invalid_since,
    do: {:error, :bad_request, "Query parameter 'since' must be an ISO-8601 timestamp"}

  operation(:drill,
    summary: "Progressive-disclosure drill",
    description:
      "Fetches the full body of a single article a progressive index stub pointed " <>
        "at, scope-enforced exactly like a direct fetch. Resolves both " <>
        "tenant-owned articles and published system canonicals (the same set the " <>
        "index surfaces). Role: agent+.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Article UUID to drill into.",
        required: true
      ]
    ],
    responses: %{
      200 =>
        {"Full article", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description: "The full article, including body."
             }
           }
         }},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/progressive/:id"
  def drill(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    api_key_id = conn.assigns.current_api_key.id

    # Thread api_key_id so finalize_article_read/Analytics.record_access attributes
    # the body read (parity with ArticleController.show and the hybrid endpoint) —
    # without it, every progressive-drill read is an audit/analytics blind spot.
    # No origin parameter: which access type the read records is derived server-side from the
    # branch that resolves the article (#569), so the heat-index exclusion binds every caller
    # rather than only the ones that opt in.
    opts = Keyword.merge([api_key_id: api_key_id], Visibility.scope_opts(conn))

    with {:ok, article} <-
           Knowledge.progressive_drill(tenant_id, article_id, opts) do
      json(conn, %{data: LoopctlWeb.ArticleJSON.article_data(article)})
    end
  end

  # Coerce `topic` to a binary at the transport boundary (mirror the hybrid
  # controller's `trim_query/1`). A malformed query string like `?topic[]=x`
  # makes Plug parse the param as a list; passing that straight to
  # `progressive_index` -> `search_keyword` -> `String.trim/1` would raise a
  # FunctionClauseError -> HTTP 500. Coercing a non-binary to "" yields a clean
  # `{:error, :empty_query}` -> 400 instead.
  defp coerce_topic(topic) when is_binary(topic), do: topic
  defp coerce_topic(_), do: ""

  # Only ever called with a validated `:category` (nil or an atom), so no
  # empty-string clause is needed here.
  defp maybe_add_opt(opts, _key, nil), do: opts
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

  defp maybe_add_limit(opts, nil), do: opts

  defp maybe_add_limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:limit, max(int, 1)} | opts]
      _ -> opts
    end
  end

  defp maybe_add_limit(opts, value) when is_integer(value), do: [{:limit, max(value, 1)} | opts]
  defp maybe_add_limit(opts, _), do: opts
end
