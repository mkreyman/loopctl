defmodule LoopctlWeb.AnalyticsController do
  @moduledoc """
  Controller for token analytics query endpoints.

  - `GET /api/v1/analytics/agents` -- per-agent cost metrics (orchestrator+)
  - `GET /api/v1/analytics/epics` -- per-epic cost breakdown (agent+)
  - `GET /api/v1/analytics/projects/:id` -- single project cost overview (agent+)
  - `GET /api/v1/analytics/models` -- model mix analysis (agent+)
  - `GET /api/v1/analytics/trends` -- daily/weekly cost trend (orchestrator+)

  All endpoints are read-only and return empty results when no data exists.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.TokenUsage.Analytics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:agents, :trends]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:epics, :project, :models]

  tags(["Analytics"])

  # ---------------------------------------------------------------------------
  # OpenAPI operations
  # ---------------------------------------------------------------------------

  operation(:agents,
    summary: "Per-agent cost metrics",
    description:
      "Returns per-agent cost metrics including efficiency ranking. " <>
        "Filterable by project_id and date range.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      since: [in: :query, type: :string, description: "Start date (YYYY-MM-DD)"],
      until: [in: :query, type: :string, description: "End date (YYYY-MM-DD)"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Agent metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:epics,
    summary: "Per-epic cost breakdown",
    description:
      "Returns per-epic cost breakdown including budget utilization and model breakdown. " <>
        "Filterable by project_id.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Epic metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:project,
    summary: "Single project cost overview",
    description:
      "Returns comprehensive cost overview for a single project " <>
        "including phase breakdown, model breakdown, and budget utilization.",
    parameters: [
      id: [in: :path, type: :string, description: "Project UUID"]
    ],
    responses: %{
      200 =>
        {"Project metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Project not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:models,
    summary: "Model mix analysis",
    description:
      "Returns per-model token usage, cost, and verification correlation metrics. " <>
        "Filterable by project_id and date range.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      since: [in: :query, type: :string, description: "Start date (YYYY-MM-DD)"],
      until: [in: :query, type: :string, description: "End date (YYYY-MM-DD)"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Model metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:trends,
    summary: "Daily/weekly cost trend",
    description:
      "Returns cost trend data grouped by day or week. " <>
        "Filterable by project_id and date range.",
    parameters: [
      granularity: [
        in: :query,
        type: :string,
        description: "Grouping: 'daily' (default) or 'weekly'"
      ],
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      since: [in: :query, type: :string, description: "Start date (YYYY-MM-DD)"],
      until: [in: :query, type: :string, description: "End date (YYYY-MM-DD)"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Trend metrics", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @doc """
  GET /api/v1/analytics/agents

  Returns per-agent cost metrics with efficiency ranking.
  """
  def agents(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = build_opts(params, [:project_id, :since, :until, :page, :page_size])

    {:ok, result} = Analytics.agent_metrics(tenant_id, opts)

    json(conn, %{
      data: result.data,
      meta: pagination_meta(result)
    })
  end

  @doc """
  GET /api/v1/analytics/epics

  Returns per-epic cost breakdown with budget utilization.
  """
  def epics(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = build_opts(params, [:project_id, :page, :page_size])

    {:ok, result} = Analytics.epic_metrics(tenant_id, opts)

    json(conn, %{
      data: result.data,
      meta: pagination_meta(result)
    })
  end

  @doc """
  GET /api/v1/analytics/projects/:id

  Returns single project cost overview.
  """
  def project(conn, %{"id" => project_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, metrics} <- Analytics.project_metrics(tenant_id, project_id) do
      json(conn, %{data: metrics})
    end
  end

  @doc """
  GET /api/v1/analytics/models

  Returns model mix analysis with verification correlation.
  """
  def models(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = build_opts(params, [:project_id, :since, :until, :page, :page_size])

    {:ok, result} = Analytics.model_metrics(tenant_id, opts)

    json(conn, %{
      data: result.data,
      meta: pagination_meta(result)
    })
  end

  @doc """
  GET /api/v1/analytics/trends

  Returns daily or weekly cost trend.
  """
  def trends(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      build_opts(params, [:project_id, :since, :until, :page, :page_size, :granularity])

    {:ok, result} = Analytics.trend_metrics(tenant_id, opts)

    json(conn, %{
      data: result.data,
      meta: pagination_meta(result)
    })
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_opts(params, allowed_keys) do
    Enum.reduce(allowed_keys, [], fn key, acc ->
      str_key = Atom.to_string(key)

      case {key, Map.get(params, str_key)} do
        {_, nil} -> acc
        {:page, val} -> maybe_add_opt(acc, :page, parse_int(val))
        {:page_size, val} -> maybe_add_opt(acc, :page_size, parse_int(val))
        {:since, val} -> maybe_add_opt(acc, :since, parse_date(val))
        {:until, val} -> maybe_add_opt(acc, :until, parse_date(val))
        {:project_id, val} -> maybe_add_opt(acc, :project_id, val)
        {:granularity, val} -> maybe_add_opt(acc, :granularity, val)
        _ -> acc
      end
    end)
  end

  defp pagination_meta(result) do
    %{
      page: result.page,
      page_size: result.page_size,
      total_count: result.total,
      total_pages: ceil_div(result.total, result.page_size)
    }
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp parse_date(nil), do: nil

  defp parse_date(val) when is_binary(val) do
    case Date.from_iso8601(val) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(%Date{} = date), do: date

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)
end
