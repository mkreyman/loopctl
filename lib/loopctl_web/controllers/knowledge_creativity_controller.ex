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
        "link graph (≤2 hops) are returned. Each pair: `{a, b, distance}`. Samples up to " <>
        "1000 embedded published articles (lowest-id slice; operator-tunable). " <>
        "`meta` carries `count`/`total_count`/`has_more` for pagination. Role: agent+.",
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
           Knowledge.distant_pairs(tenant_id,
             min_distance: min_d,
             max_distance: max_d,
             bridge_path: params["bridge_path"] == "true",
             limit: parse_int(params["limit"]) || 20,
             offset: parse_int(params["offset"]) || 0
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
        "opposite vectors; nil if idea text is blank or priors exist). Each idea's text " <>
        "is embedded on the fly. Priors default to published articles tagged `proposal` " <>
        "(override with `prior_tag`). Body: `{ideas: [{text|title/spark/thesis...}], " <>
        "prior_tag?}`. Role: agent+.",
    request_body:
      {"Ideas to score", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:ideas],
         properties: %{
           ideas: %OpenApiSpex.Schema{type: :array},
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
                   description: "Number of prior proposals"
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

    with {:ok, ideas} <- validate_ideas(params["ideas"]) do
      opts = if is_binary(params["prior_tag"]), do: [prior_tag: params["prior_tag"]], else: []
      prior_tag = Keyword.get(opts, :prior_tag, "proposal")
      {:ok, scored} = Knowledge.novelty_scores(tenant_id, ideas, opts)
      prior_count = Knowledge.count_articles(tenant_id, status: :published, tags: [prior_tag])
      json(conn, %{data: scored, meta: %{prior_count: prior_count}})
    end
  end

  operation(:walk,
    summary: "Random walk through the link graph",
    description:
      "Returns a random walk of up to `length` published articles starting from " <>
        "`start_id`, following random unvisited link-graph neighbors (no cycles; stops at " <>
        "a dead end). Surfaces unexpected connections. Role: agent+.",
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
           Knowledge.random_walk(tenant_id, start_id, length: parse_int(params["length"]) || 4) do
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

  defp validate_ideas(ideas) when is_list(ideas) and ideas != [] do
    cond do
      length(ideas) > @max_novelty_ideas ->
        {:error, :bad_request, "ideas must not exceed #{@max_novelty_ideas} per request"}

      not Enum.all?(ideas, &is_map/1) ->
        {:error, :bad_request, "each idea must be an object"}

      true ->
        {:ok, ideas}
    end
  end

  defp validate_ideas(_), do: {:error, :bad_request, "ideas must be a non-empty array"}
end
