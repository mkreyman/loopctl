defmodule LoopctlWeb.AnalyticsController do
  @moduledoc """
  Controller for token analytics query endpoints.

  - `GET /api/v1/analytics/agents` -- per-agent cost metrics (orchestrator+)
  - `GET /api/v1/analytics/epics` -- per-epic cost breakdown (agent+)
  - `GET /api/v1/analytics/projects/:id` -- single project cost overview (agent+)
  - `GET /api/v1/analytics/models` -- model mix analysis (agent+)
  - `GET /api/v1/analytics/trends` -- daily/weekly cost trend (orchestrator+)
  - `GET /api/v1/analytics/model-mix` -- model-mix correlation matrix (orchestrator+)
  - `GET /api/v1/analytics/agents/:id/model-profile` -- agent model profile (orchestrator+)

  All endpoints are read-only and return empty results when no data exists.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.TokenUsage.Analytics

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :orchestrator] when action in [:agents, :trends, :model_mix, :agent_model_profile]

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:epics, :project, :models]

  tags(["Token Efficiency"])

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
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: Schemas.TokenAnalyticsAgent
             },
             meta: Schemas.PaginationMeta
           }
         }},
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
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: Schemas.TokenAnalyticsEpic
             },
             meta: Schemas.PaginationMeta
           }
         }},
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
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: Schemas.TokenAnalyticsProject
           }
         }},
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
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: Schemas.TokenAnalyticsModel
             },
             meta: Schemas.PaginationMeta
           }
         }},
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
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :array,
               items: Schemas.TokenAnalyticsTrend
             },
             meta: Schemas.PaginationMeta
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:model_mix,
    summary: "Model-mix correlation matrix",
    description:
      "Returns a (model_name, phase) correlation matrix with token totals, cost, " <>
        "stories count, and verification outcomes. Includes comparative view: " <>
        "mixed-model vs single-model agent averages. " <>
        "Filterable by project_id, agent_id, and date range.",
    parameters: [
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      agent_id: [in: :query, type: :string, description: "Filter by agent UUID"],
      since: [in: :query, type: :string, description: "Start date (YYYY-MM-DD)"],
      until: [in: :query, type: :string, description: "End date (YYYY-MM-DD)"]
    ],
    responses: %{
      200 =>
        {"Model-mix matrix", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description:
                 "Model-mix correlation matrix keyed by (model_name, phase). " <>
                   "Includes comparative view: mixed-model vs single-model agent averages.",
               properties: %{
                 matrix: %OpenApiSpex.Schema{
                   type: :array,
                   items: Schemas.ModelMixEntry
                 },
                 comparative: %OpenApiSpex.Schema{
                   type: :object,
                   additionalProperties: true,
                   description: "Mixed-model vs single-model agent average cost comparison"
                 }
               }
             }
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:agent_model_profile,
    summary: "Agent model usage profile",
    description:
      "Returns a specific agent's model usage profile across phases. " <>
        "Includes model_count and is_model_blender (true if agent uses more than one model). " <>
        "Filterable by project_id and date range.",
    parameters: [
      id: [in: :path, type: :string, description: "Agent UUID"],
      project_id: [in: :query, type: :string, description: "Filter by project UUID"],
      since: [in: :query, type: :string, description: "Start date (YYYY-MM-DD)"],
      until: [in: :query, type: :string, description: "End date (YYYY-MM-DD)"]
    ],
    responses: %{
      200 =>
        {"Agent model profile", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           description:
             "Agent's model usage profile across phases. " <>
               "Includes model_count and is_model_blender flag.",
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 agent_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
                 agent_name: %OpenApiSpex.Schema{type: :string},
                 model_count: %OpenApiSpex.Schema{
                   type: :integer,
                   description: "Number of distinct models used"
                 },
                 is_model_blender: %OpenApiSpex.Schema{
                   type: :boolean,
                   description: "True if agent uses more than one model"
                 },
                 models: %OpenApiSpex.Schema{
                   type: :array,
                   items: %OpenApiSpex.Schema{type: :object, additionalProperties: true},
                   description: "Per-model usage breakdown across phases"
                 }
               }
             }
           }
         }},
      404 => {"Agent not found", "application/json", Schemas.ErrorResponse},
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

  @doc """
  GET /api/v1/analytics/model-mix

  Returns model-mix correlation matrix with comparative view.
  """
  def model_mix(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = build_opts(params, [:project_id, :agent_id, :since, :until])

    {:ok, result} = Analytics.model_mix(tenant_id, opts)

    json(conn, %{data: result})
  end

  @doc """
  GET /api/v1/analytics/agents/:id/model-profile

  Returns a specific agent's model usage profile.
  """
  def agent_model_profile(conn, %{"id" => agent_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    opts = build_opts(params, [:project_id, :since, :until])

    with {:ok, profile} <- Analytics.agent_model_profile(tenant_id, agent_id, opts) do
      json(conn, %{data: profile})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_opts(params, allowed_keys) do
    Enum.reduce(allowed_keys, [], fn key, acc ->
      val = Map.get(params, Atom.to_string(key))
      maybe_add_opt(acc, key, parse_opt(key, val))
    end)
  end

  # String passthrough keys
  @string_keys [:project_id, :agent_id, :granularity]

  defp parse_opt(_key, nil), do: nil
  defp parse_opt(key, val) when key in @string_keys, do: val
  defp parse_opt(:page, val), do: parse_int(val)
  defp parse_opt(:page_size, val), do: parse_int(val)
  defp parse_opt(:since, val), do: parse_date(val)
  defp parse_opt(:until, val), do: parse_date(val)
  defp parse_opt(_key, _val), do: nil

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
