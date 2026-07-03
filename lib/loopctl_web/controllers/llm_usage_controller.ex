defmodule LoopctlWeb.LlmUsageController do
  @moduledoc """
  Per-tenant LLM token-usage summary (Epic 28 residual, #179).

  - `GET /api/v1/knowledge/llm-usage` — usage grouped by operation + model +
    source_type + day, over an optional date range, with offset/limit pagination.

  Record-only reporting (there is NO budget enforcement). Role: orchestrator+ so
  an autonomous orchestrator can monitor consumption; the data is the tenant's own
  aggregate token counts (no secret).
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Llm

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Wiki"])

  operation(:index,
    summary: "Per-tenant LLM usage summary",
    description:
      "Returns token usage for the current tenant grouped by operation + model + " <>
        "source_type + day, newest day first, with offset/limit pagination over " <>
        "`meta.total_count`. Optional `from`/`to` (ISO 8601) narrow the window. " <>
        "Record-only — no budget enforcement. Role: orchestrator+.",
    parameters: [
      from: [
        in: :query,
        type: :string,
        description:
          "Optional ISO 8601 lower bound (inclusive) on occurred_at. Defaults to a " <>
            "90-day lookback when omitted; the effective window is echoed in `meta.from`/`meta.to`.",
        required: false
      ],
      to: [
        in: :query,
        type: :string,
        description: "Optional ISO 8601 upper bound (inclusive) on occurred_at",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max rows per page (default 50, clamped to 200)",
        required: false
      ],
      offset: [
        in: :query,
        type: :integer,
        description: "Rows to skip (default 0)",
        required: false
      ]
    ],
    responses: %{
      200 => {"Usage summary", "application/json", Schemas.LlmUsageResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/llm-usage"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts = [
      from: parse_datetime(params["from"]),
      to: parse_datetime(params["to"]),
      limit: parse_int(params["limit"]),
      offset: parse_int(params["offset"])
    ]

    summary = Llm.usage_summary(tenant_id, Enum.reject(opts, fn {_k, v} -> is_nil(v) end))
    json(conn, summary)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
