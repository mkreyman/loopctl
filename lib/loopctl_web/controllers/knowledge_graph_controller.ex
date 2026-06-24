defmodule LoopctlWeb.KnowledgeGraphController do
  @moduledoc """
  Multi-hop knowledge-graph traversal.

  - `GET /api/v1/knowledge/graph?article_id=&depth=` -- traverse the published
    article-link graph outward from an article (agent+).

  Returns reachable published articles visible to the caller and the links among them,
  bidirectional and cycle-safe, bounded to 100 nodes / 500 edges (`truncated` flags a cap hit).
  Agent callers see only their own articles and `shared` articles.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:graph,
    summary: "Traverse the knowledge graph",
    description:
      "Walks the published article-link graph outward from `article_id` up to `depth` " <>
        "hops (1–3, default 1), respecting visibility (agent callers see only their own and `shared` articles). " <>
        "**Bidirectional** (links followed regardless of source/" <>
        "target direction) and **cycle-safe** (no node appears twice). Returns `nodes` " <>
        "(`id`, `title`, `category`, `depth`), `edges` (`source_article_id`, " <>
        "`target_article_id`, `relationship_type`), `truncated`, and `node_count`. " <>
        "Bounded to 100 nodes / 500 edges; `truncated: true` when a cap is hit. Only " <>
        "published articles are traversed; bounded to visible articles. Role: agent+.",
    parameters: [
      article_id: [in: :query, type: :string, description: "Starting article UUID (required)"],
      depth: [in: :query, type: :integer, description: "Hops to traverse (1–3, default 1)"],
      project_id: [in: :query, type: :string, description: "Optional project UUID (attribution)"]
    ],
    responses: %{
      200 =>
        {"Graph", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             nodes: %OpenApiSpex.Schema{type: :array},
             edges: %OpenApiSpex.Schema{type: :array},
             truncated: %OpenApiSpex.Schema{type: :boolean},
             node_count: %OpenApiSpex.Schema{type: :integer}
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      404 => {"Article not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/graph"
  def graph(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, article_id} <- require_article_id(params["article_id"]),
         {:ok, depth} <- parse_depth(params["depth"]),
         {:ok, result} <-
           Knowledge.graph_traversal(
             tenant_id,
             article_id,
             [depth: depth] ++ Visibility.scope_opts(conn)
           ) do
      json(conn, result)
    else
      {:error, :invalid_depth} ->
        {:error, :bad_request, "depth must be an integer between 1 and 3"}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :bad_request, _message} = error ->
        error
    end
  end

  defp require_article_id(value) when value in [nil, ""],
    do: {:error, :bad_request, "article_id is required"}

  defp require_article_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, "article_id must be a UUID"}
    end
  end

  defp require_article_id(_), do: {:error, :bad_request, "article_id must be a UUID"}

  defp parse_depth(value) when value in [nil, ""], do: {:ok, 1}

  defp parse_depth(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_depth}
    end
  end

  defp parse_depth(_), do: {:error, :invalid_depth}
end
