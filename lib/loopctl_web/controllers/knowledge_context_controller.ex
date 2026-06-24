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
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  @max_csv_list_size 25
  @max_csv_item_length 200
  @max_conversation_id_length 200

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
      ],
      status: [
        in: :query,
        type: :string,
        description:
          "Article status filter (published, draft, archived). " <>
            "Only effective for user/superadmin roles. " <>
            "Agent/orchestrator roles are forced to published.",
        required: false
      ],
      memory_types: [
        in: :query,
        type: :string,
        description:
          "Agent-memory scope: comma-separated memory_types (OR) — " <>
            "observation|finding|summary|decision|question|task. Filters via metadata @>.",
        required: false
      ],
      agents: [
        in: :query,
        type: :string,
        description:
          "Agent-memory scope: comma-separated agent_ids (OR). Filters via metadata @>.",
        required: false
      ],
      conversation_id: [
        in: :query,
        type: :string,
        description: "Agent-memory scope: exact conversation_id. Filters via metadata @>.",
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
    api_key_id = conn.assigns.current_api_key.id
    role = conn.assigns.current_api_key.role

    with {:ok, query} <- validate_query(params) do
      opts =
        params
        |> build_opts(role)
        |> Keyword.put(:api_key_id, api_key_id)
        |> Keyword.merge(Visibility.scope_opts(conn))

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
      |> maybe_add_csv(:memory_types, params["memory_types"])
      |> maybe_add_csv(:agents, params["agents"])
      |> maybe_add_conversation_id(params["conversation_id"])

    # Agent role forced to published; user role can override via ?status= param
    role_atom = if is_binary(role), do: String.to_existing_atom(role), else: role

    if role_atom in [:agent, :orchestrator] do
      [{:status, :published} | opts]
    else
      maybe_add_status(opts, params["status"])
    end
  end

  defp maybe_add_project_id(opts, nil), do: opts
  defp maybe_add_project_id(opts, ""), do: opts
  defp maybe_add_project_id(opts, project_id), do: [{:project_id, project_id} | opts]

  @valid_statuses ~w(published draft archived)
  defp maybe_add_status(opts, nil), do: opts
  defp maybe_add_status(opts, ""), do: opts

  defp maybe_add_status(opts, value) when is_binary(value) do
    if value in @valid_statuses do
      [{:status, String.to_existing_atom(value)} | opts]
    else
      opts
    end
  end

  defp maybe_add_status(opts, _), do: opts

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

  # Comma-separated value → list (OR semantics in the query). Absent/blank → no opt.
  # Caps: max 25 items per list, max 200 chars per item. Excess items silently dropped,
  # items exceeding length are truncated. For memory_types, only valid types are kept.
  defp maybe_add_csv(opts, _key, value) when value in [nil, ""], do: opts

  defp maybe_add_csv(opts, key, value) when is_binary(value) do
    case value
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
         |> Enum.take(@max_csv_list_size)
         |> Enum.map(&String.slice(&1, 0, @max_csv_item_length)) do
      [] ->
        opts

      list when key == :memory_types ->
        # Only keep valid memory types; others are silently dropped
        valid_types = Article.valid_memory_types()
        filtered = Enum.filter(list, &(&1 in valid_types))

        if Enum.empty?(filtered) do
          opts
        else
          [{key, filtered} | opts]
        end

      list ->
        [{key, list} | opts]
    end
  end

  defp maybe_add_csv(opts, _key, _), do: opts

  defp maybe_add_conversation_id(opts, value) when value in [nil, ""], do: opts

  defp maybe_add_conversation_id(opts, value) when is_binary(value) do
    truncated = String.slice(value, 0, @max_conversation_id_length)
    [{:conversation_id, truncated} | opts]
  end

  defp maybe_add_conversation_id(opts, _), do: opts
end
