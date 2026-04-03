defmodule LoopctlWeb.CostAnomalyController do
  @moduledoc """
  Controller for cost anomaly management.

  - `GET /api/v1/cost-anomalies` -- list unresolved anomalies (user+)
  - `PATCH /api/v1/cost-anomalies/:id` -- mark anomaly as resolved (user+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.TokenUsage

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  tags(["Cost Anomalies"])

  operation(:index,
    summary: "List cost anomalies",
    description:
      "Returns unresolved cost anomalies for the tenant. " <>
        "Filterable by anomaly_type and project_id. " <>
        "Includes story title and agent name.",
    parameters: [
      anomaly_type: [
        in: :query,
        type: :string,
        description: "Filter by anomaly type: high_cost, suspiciously_low, budget_exceeded"
      ],
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Anomaly list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
             },
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Resolve cost anomaly",
    description: "Marks a cost anomaly as resolved.",
    parameters: [
      id: [in: :path, type: :string, description: "Anomaly UUID"]
    ],
    responses: %{
      200 =>
        {"Anomaly resolved", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Anomaly not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/cost-anomalies

  Lists unresolved cost anomalies for the tenant.
  """
  def index(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:anomaly_type, params["anomaly_type"])
      |> maybe_add_opt(:project_id, params["project_id"])
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = TokenUsage.list_anomalies(tenant_id, opts)

    json(conn, %{
      data: result.data,
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  PATCH /api/v1/cost-anomalies/:id

  Marks a cost anomaly as resolved.
  """
  def update(conn, %{"id" => id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, anomaly} <- TokenUsage.resolve_anomaly(tenant_id, id) do
      json(conn, %{
        cost_anomaly: %{
          id: anomaly.id,
          resolved: anomaly.resolved,
          updated_at: anomaly.updated_at
        }
      })
    end
  end

  # --- Private helpers ---

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
