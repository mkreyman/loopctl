defmodule LoopctlWeb.KnowledgeContextController do
  @moduledoc """
  Controller for the deep-read knowledge context endpoint.

  - `GET /api/v1/knowledge/context` -- returns full article bodies ranked by
    combined relevance + recency, with one-hop linked article references (agent+)

  Unlike the search endpoint (which returns snippets), this endpoint returns
  the complete article body for each result, enabling agents to consume full
  context without additional round-trips.

  Scoring: `combined_score = (1 - recency_weight) * relevance + recency_weight * recency_score`
  where `recency_score = exp(-age_in_days / 30.0)`.

  Agent role is forced to `status: :published`. User role may override via
  query parameter.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:context,
    summary: "Deep-read knowledge context",
    description:
      "Returns full article bodies ranked by combined relevance + recency scoring. " <>
        "Each result includes one-hop linked article references (max 5 per result). " <>
        "Falls back to keyword-only search if embedding generation fails. " <>
        "Agent role is forced to published articles. Role: agent+.",
    parameters: [
      query: [
        in: :query,
        type: :string,
        description: "Search query (required, max 500 characters)",
        required: true
      ],
      project_id: [
        in: :query,
        type: :string,
        description: "Filter by project UUID",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max results to return (default 5, max 20)",
        required: false
      ],
      recency_weight: [
        in: :query,
        type: :number,
        description:
          "Weight for recency scoring, 0.0-1.0 (default 0.3). " <>
            "Higher values boost recently-updated articles.",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Context results", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               description: "Articles with full body, scores, and linked references"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 limit: %OpenApiSpex.Schema{type: :integer},
                 fallback: %OpenApiSpex.Schema{type: :boolean},
                 recency_weight: %OpenApiSpex.Schema{type: :number}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/context"
  def context(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    role = conn.assigns.current_api_key.role

    with {:ok, query} <- validate_query(params) do
      opts = build_opts(params, role)

      case Knowledge.get_context(tenant_id, query, opts) do
        {:ok, result} ->
          json(conn, LoopctlWeb.KnowledgeContextJSON.context(result))

        {:error, :empty_query} ->
          {:error, :bad_request, "Query parameter 'query' is required and cannot be empty"}
      end
    end
  end

  defp validate_query(%{"query" => q}) when is_binary(q) do
    trimmed = String.trim(q)

    cond do
      trimmed == "" ->
        {:error, :bad_request, "Query parameter 'query' is required and cannot be empty"}

      String.length(trimmed) > 500 ->
        {:error, :bad_request, "Query parameter 'query' exceeds maximum length of 500 characters"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_query(_) do
    {:error, :bad_request, "Query parameter 'query' is required and cannot be empty"}
  end

  defp build_opts(params, role) do
    opts =
      []
      |> maybe_add_project_id(params["project_id"])
      |> maybe_add_limit(params["limit"])
      |> maybe_add_recency_weight(params["recency_weight"])

    # Agent role forced to published; user role can override
    role_atom = if is_binary(role), do: String.to_existing_atom(role), else: role

    if role_atom in [:agent, :orchestrator] do
      [{:status, :published} | opts]
    else
      opts
    end
  end

  defp maybe_add_project_id(opts, nil), do: opts
  defp maybe_add_project_id(opts, ""), do: opts
  defp maybe_add_project_id(opts, project_id), do: [{:project_id, project_id} | opts]

  defp maybe_add_limit(opts, nil), do: opts

  defp maybe_add_limit(opts, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> [{:limit, int} | opts]
      _ -> opts
    end
  end

  defp maybe_add_limit(opts, value) when is_integer(value), do: [{:limit, value} | opts]
  defp maybe_add_limit(opts, _), do: opts

  defp maybe_add_recency_weight(opts, nil), do: opts

  defp maybe_add_recency_weight(opts, value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> [{:recency_weight, float} | opts]
      {float, _} -> [{:recency_weight, float} | opts]
      :error -> opts
    end
  end

  defp maybe_add_recency_weight(opts, value) when is_number(value) do
    [{:recency_weight, value / 1} | opts]
  end

  defp maybe_add_recency_weight(opts, _), do: opts
end
