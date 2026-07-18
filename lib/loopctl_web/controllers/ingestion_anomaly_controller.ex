defmodule LoopctlWeb.IngestionAnomalyController do
  @moduledoc """
  Controller for ingestion capture-silence anomaly management.

  - `GET /api/v1/ingestion-anomalies` -- list unresolved anomalies (orchestrator+)
  - `PATCH /api/v1/ingestion-anomalies/:id` -- mark anomaly as resolved, or
    `?archived=true` to permanently archive a retired source_type (user+)

  Role gating mirrors `LoopctlWeb.CostAnomalyController` exactly: listing at the
  same read role cost anomalies use, and resolution at `:user` (a custody-adjacent
  action, additionally human-anchor gated).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge.IngestionHealth

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:index]
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:update]

  # Work-breakdown / custody-adjacent surface requires a human-anchored tenant.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:update]

  tags(["Knowledge Wiki"])

  operation(:index,
    summary: "List ingestion capture-silence anomalies",
    description:
      "Returns unresolved ingestion capture-silence anomalies for the tenant. " <>
        "Filterable by source_type and anomaly_type. " <>
        "Archived anomalies are excluded by default; use ?include_archived=true to include them.",
    parameters: [
      source_type: [
        in: :query,
        type: :string,
        description: "Filter by monitored article source_type (e.g. session_log)"
      ],
      anomaly_type: [
        in: :query,
        type: :string,
        description: "Filter by anomaly type: capture_silence"
      ],
      include_archived: [
        in: :query,
        type: :boolean,
        description: "Include archived anomalies (default: false)"
      ],
      resolved: [
        in: :query,
        type: :boolean,
        description:
          "Filter by resolved status. true = resolved only, false = unresolved only (default: false)"
      ],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Anomaly list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :object}},
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Resolve or archive ingestion anomaly",
    description:
      "Marks an ingestion capture-silence anomaly as resolved. Pass ?archived=true to " <>
        "instead ARCHIVE it — the permanent escape hatch for a retired source_type, which " <>
        "hides it from the default list and suppresses re-detection.",
    parameters: [
      id: [in: :path, type: :string, description: "Anomaly UUID"],
      archived: [
        in: :query,
        type: :boolean,
        description: "When true, archive (permanently suppress) instead of resolve"
      ]
    ],
    responses: %{
      200 =>
        {"Anomaly resolved or archived", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           description: "Confirmation of resolution or archival",
           properties: %{
             ingestion_anomaly: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                 resolved: %OpenApiSpex.Schema{type: :boolean, example: true},
                 archived: %OpenApiSpex.Schema{type: :boolean, example: false},
                 updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
               }
             }
           }
         }},
      404 => {"Anomaly not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/ingestion-anomalies

  Lists unresolved ingestion capture-silence anomalies for the tenant.
  """
  def index(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts =
      []
      |> maybe_add_opt(:source_type, params["source_type"])
      |> maybe_add_opt(:anomaly_type, params["anomaly_type"])
      |> maybe_add_opt(:include_archived, parse_bool(params["include_archived"]))
      |> maybe_add_opt(:resolved, parse_bool(params["resolved"]))
      |> maybe_add_opt(:page, parse_int(params["page"]))
      |> maybe_add_opt(:page_size, parse_int(params["page_size"]))

    {:ok, result} = IngestionHealth.list_anomalies(tenant_id, opts)

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
  PATCH /api/v1/ingestion-anomalies/:id

  Marks an ingestion anomaly as resolved, or archives it when `?archived=true`.
  """
  def update(conn, %{"id" => id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    audit_opts = [
      actor_id: api_key.id,
      actor_label: api_key.name,
      actor_type: "api_key"
    ]

    result =
      if parse_bool(params["archived"]) == true do
        IngestionHealth.archive_anomaly(tenant_id, id, audit_opts)
      else
        IngestionHealth.resolve_anomaly(tenant_id, id, audit_opts)
      end

    with {:ok, anomaly} <- result do
      json(conn, %{
        ingestion_anomaly: %{
          id: anomaly.id,
          resolved: anomaly.resolved,
          archived: anomaly.archived,
          updated_at: anomaly.updated_at
        }
      })
    end
  end

  # --- Private helpers ---

  defp parse_bool(nil), do: nil
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool(_), do: nil

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
