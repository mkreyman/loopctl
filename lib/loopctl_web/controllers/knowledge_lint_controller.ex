defmodule LoopctlWeb.KnowledgeLintController do
  @moduledoc """
  Controller for the knowledge lint operation.

  - `GET /api/v1/knowledge/lint` -- tenant-wide lint report (orchestrator+)
  - `GET /api/v1/projects/:project_id/knowledge/lint` -- project-scoped lint report (orchestrator+)

  Analyzes published articles and returns a structured report of potential
  issues: stale articles, orphaned articles, contradiction clusters,
  coverage gaps, and broken source references.

  This endpoint is read-only -- no data is modified.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Wiki"])

  operation(:lint,
    summary: "Knowledge lint report",
    description:
      "Analyzes published articles and returns a structured report of potential " <>
        "issues including stale articles, orphaned articles, contradiction clusters, " <>
        "coverage gaps, and broken source references. Read-only operation. " <>
        "When called via GET /projects/:project_id/knowledge/lint, scopes analysis " <>
        "to project-specific and tenant-wide articles. Role: orchestrator+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped lint)",
        required: false
      ],
      stale_days: [
        in: :query,
        type: :integer,
        description:
          "Number of days without update before an article is considered stale (default 90)",
        required: false
      ],
      min_coverage: [
        in: :query,
        type: :integer,
        description:
          "Minimum published articles per category to avoid a coverage gap (default 3)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Knowledge lint report", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description: "Lint findings grouped by issue type"
             },
             summary: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_articles: %OpenApiSpex.Schema{type: :integer},
                 total_issues: %OpenApiSpex.Schema{type: :integer},
                 issues_by_severity: %OpenApiSpex.Schema{type: :object},
                 generated_at: %OpenApiSpex.Schema{type: :string}
               }
             }
           }
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/lint or GET /api/v1/projects/:project_id/knowledge/lint"
  def lint(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, opts} <- parse_lint_params(params) do
      {:ok, result} = Knowledge.lint(tenant_id, opts)
      json(conn, LoopctlWeb.KnowledgeLintJSON.lint(result))
    end
  end

  defp parse_lint_params(params) do
    opts = []

    opts =
      case params["project_id"] do
        nil -> opts
        project_id -> Keyword.put(opts, :project_id, project_id)
      end

    with {:ok, opts} <- parse_stale_days(params, opts) do
      parse_min_coverage(params, opts)
    end
  end

  defp parse_stale_days(%{"stale_days" => raw}, opts) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 ->
        {:ok, Keyword.put(opts, :stale_days, n)}

      _ ->
        {:error, :bad_request, "stale_days must be a positive integer"}
    end
  end

  defp parse_stale_days(%{"stale_days" => n}, opts) when is_integer(n) and n > 0 do
    {:ok, Keyword.put(opts, :stale_days, n)}
  end

  defp parse_stale_days(%{"stale_days" => _}, _opts) do
    {:error, :bad_request, "stale_days must be a positive integer"}
  end

  defp parse_stale_days(_params, opts), do: {:ok, opts}

  defp parse_min_coverage(%{"min_coverage" => raw}, opts) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 ->
        {:ok, Keyword.put(opts, :min_coverage, n)}

      _ ->
        {:error, :bad_request, "min_coverage must be a positive integer"}
    end
  end

  defp parse_min_coverage(%{"min_coverage" => n}, opts) when is_integer(n) and n > 0 do
    {:ok, Keyword.put(opts, :min_coverage, n)}
  end

  defp parse_min_coverage(%{"min_coverage" => _}, _opts) do
    {:error, :bad_request, "min_coverage must be a positive integer"}
  end

  defp parse_min_coverage(_params, opts), do: {:ok, opts}
end
