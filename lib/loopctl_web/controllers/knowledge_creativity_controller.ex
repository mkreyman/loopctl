defmodule LoopctlWeb.KnowledgeCreativityController do
  @moduledoc """
  Creativity-support primitives over the embedding space + link graph (#152):

  - `GET  /api/v1/knowledge/pairs` — distant-but-bridgeable article pairs (agent+)
  - `POST /api/v1/knowledge/novelty` — novelty score (distance to nearest prior) (agent+)
  - `GET  /api/v1/knowledge/walk` — random walk through the link graph (agent+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  @max_novelty_ideas 50

  operation(:pairs,
    summary: "Distant-but-bridgeable article pairs",
    description:
      "Returns paginated pairs of articles whose embedding cosine distance is in the " <>
        "optimal-novelty band [`min_distance`, `max_distance`] (default 0.3–0.7) — the " <>
        "creative sweet spot. With `bridge_path=true`, only pairs also connected in the " <>
        "link graph (≤2 hops) are returned. Agent callers see only their own and `shared` " <>
        "articles. Each pair: `{a, b, distance}`. Samples up to " <>
        "1000 embedded published visible articles (lowest-id slice; operator-tunable). " <>
        "`meta` carries `count`/`total_count`/`has_more` for pagination — `total_count` is " <>
        "over the sampled visible slice, so it can undercount on tenants with >1000 embedded " <>
        "articles. Role: agent+.",
    parameters: [
      min_distance: [
        in: :query,
        type: :number,
        description: "Lower cosine-distance bound (default 0.3)"
      ],
      max_distance: [
        in: :query,
        type: :number,
        description: "Upper cosine-distance bound (default 0.7)"
      ],
      bridge_path: [
        in: :query,
        type: :boolean,
        description: "Require a ≤2-hop graph path (default false)"
      ],
      limit: [in: :query, type: :integer, description: "Max pairs (default 20, max 100)"],
      offset: [in: :query, type: :integer, description: "Pairs to skip"]
    ],
    responses: %{
      200 =>
        {"Pairs", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Distant pairs [a, b, distance]"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 count: %OpenApiSpex.Schema{type: :integer, description: "Items in this page"},
                 total_count: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Total matching pairs"
                 },
                 has_more: %OpenApiSpex.Schema{
                   type: :boolean,
                   description: "More pairs exist beyond this page"
                 }
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/pairs"
  def pairs(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, min_d} <- parse_float(params["min_distance"], 0.3),
         {:ok, max_d} <- parse_float(params["max_distance"], 0.7),
         {:ok, result} <-
           Knowledge.distant_pairs(
             tenant_id,
             [
               min_distance: min_d,
               max_distance: max_d,
               bridge_path: params["bridge_path"] == "true",
               limit: parse_int(params["limit"]) || 20,
               offset: parse_int(params["offset"]) || 0
             ] ++ Visibility.scope_opts(conn)
           ) do
      json(conn, %{
        data: result.pairs,
        meta: %{
          count: length(result.pairs),
          total_count: result.total_count,
          has_more: result.has_more
        }
      })
    else
      {:error, :invalid_number} ->
        {:error, :bad_request, "min_distance/max_distance must be numbers"}

      {:error, :invalid_distance} ->
        {:error, :bad_request,
         "distance band must satisfy 0.0 <= min_distance <= max_distance <= 2.0"}
    end
  end

  operation(:novelty,
    summary: "Novelty score (distance to nearest prior)",
    description:
      "For each idea, returns `novelty_score` = cosine distance to its nearest prior " <>
        "proposal (0 = identical to existing work, higher = more novel, up to 2.0 = " <>
        "opposite vectors; `null` when the idea text is blank, no priors exist, or " <>
        "embedding fails). Each idea's text is embedded on the fly. Priors default to " <>
        "published articles tagged `proposal` visible to the caller (agent callers see only " <>
        "their own and `shared` articles; override with `prior_tag`). `meta.prior_count` " <>
        "is the number of embedded visible priors actually compared against (0 ⇒ every score is " <>
        "null). Body: provide the ideas as EITHER `texts: [\"...\", ...]` (strings) OR " <>
        "`ideas: [...]` where each element is a string or an object " <>
        "`{text|title/spark/thesis,...}`; all forms are coerced to ideas. Optional " <>
        "`prior_tag` (default `proposal`) selects the prior corpus. Returns " <>
        "`{data: [{...idea, novelty_score}], meta: {prior_count}}`. Role: agent+.",
    request_body:
      {"Ideas to score (texts:[string] or ideas:[string|object])", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           ideas: %OpenApiSpex.Schema{
             type: :array,
             description: "Strings or objects ({text|title/spark/thesis,...})"
           },
           texts: %OpenApiSpex.Schema{
             type: :array,
             items: %OpenApiSpex.Schema{type: :string},
             description: "Alternative to `ideas`: a list of idea strings (#152 AC shape)"
           },
           prior_tag: %OpenApiSpex.Schema{type: :string}
         }
       }},
    responses: %{
      200 =>
        {"Scored ideas", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description:
                 "Ideas with novelty_score (cosine distance to nearest prior, [0,2] or nil)"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 prior_count: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Number of embedded priors compared against (0 ⇒ all scores null)"
                 }
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/knowledge/novelty"
  def novelty(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, ideas} <- normalize_ideas(params) do
      base = if is_binary(params["prior_tag"]), do: [prior_tag: params["prior_tag"]], else: []
      opts = base ++ Visibility.scope_opts(conn)
      {:ok, scored, prior_count} = Knowledge.novelty_scores(tenant_id, ideas, opts)
      json(conn, %{data: scored, meta: %{prior_count: prior_count}})
    end
  end

  operation(:walk,
    summary: "Random walk through the link graph",
    description:
      "Returns a random walk of up to `length` published articles visible to the caller " <>
        "starting from `start_id`, following random unvisited link-graph neighbors (no cycles; stops at " <>
        "a dead end). Agent callers see only their own and `shared` articles. Surfaces unexpected connections. Role: agent+.",
    parameters: [
      start_id: [in: :query, type: :string, description: "Starting article UUID (required)"],
      length: [in: :query, type: :integer, description: "Walk steps (default 4, max 25)"]
    ],
    responses: %{
      200 =>
        {"Walk", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Sequence of articles in the random walk"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 count: %OpenApiSpex.Schema{type: :integer, description: "Steps in the walk"}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      404 => {"Article not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/walk"
  def walk(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, start_id} <- require_uuid(params["start_id"], "start_id"),
         {:ok, walk} <-
           Knowledge.random_walk(
             tenant_id,
             start_id,
             [length: parse_int(params["length"]) || 4] ++ Visibility.scope_opts(conn)
           ) do
      json(conn, %{data: walk, meta: %{count: length(walk)}})
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :bad_request, _} = error -> error
    end
  end

  # --- Helpers ---

  defp parse_float(value, default) when value in [nil, ""], do: {:ok, default}

  defp parse_float(value, _default) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_number}
    end
  end

  defp parse_float(_, _), do: {:error, :invalid_number}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp require_uuid(value, field) when value in [nil, ""],
    do: {:error, :bad_request, "#{field} is required"}

  defp require_uuid(value, field) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, "#{field} must be a UUID"}
    end
  end

  defp require_uuid(_, field), do: {:error, :bad_request, "#{field} must be a UUID"}

  # Accept either shape (#169): the #152 AC / CREATIVITY.md `texts: [string]`, the
  # richer `ideas: [{text|title/spark/thesis,...}]`, or a bare `ideas: [string]`.
  # All are coerced to idea objects so the documented contract and the
  # idea-synthesizer consumer agree.
  defp normalize_ideas(params) do
    raw = resolve_ideas_param(params)

    cond do
      not is_list(raw) or raw == [] ->
        {:error, :bad_request,
         "provide a non-empty `ideas` (objects or strings) or `texts` (strings) array"}

      length(raw) > @max_novelty_ideas ->
        {:error, :bad_request, "ideas must not exceed #{@max_novelty_ideas} per request"}

      true ->
        coerced = Enum.map(raw, &coerce_idea/1)

        if Enum.any?(coerced, &(&1 == :invalid)) do
          {:error, :bad_request, "each idea must be a string or an object with a `text` field"}
        else
          {:ok, coerced}
        end
    end
  end

  # Prefer whichever of `ideas`/`texts` is a non-empty list, so an empty `ideas: []`
  # doesn't shadow a valid `texts` (an empty list is truthy in Elixir, so a plain `||`
  # would short-circuit on it). Falls through to the validation error otherwise.
  defp resolve_ideas_param(params) do
    ideas = params["ideas"]
    texts = params["texts"]

    cond do
      is_list(ideas) and ideas != [] -> ideas
      is_list(texts) and texts != [] -> texts
      true -> ideas || texts
    end
  end

  # A bare string becomes `%{"text" => string}`; an object passes through (its text
  # is resolved server-side from text/title/spark/thesis).
  defp coerce_idea(idea) when is_binary(idea), do: %{"text" => idea}
  defp coerce_idea(idea) when is_map(idea), do: idea
  defp coerce_idea(_), do: :invalid
end
