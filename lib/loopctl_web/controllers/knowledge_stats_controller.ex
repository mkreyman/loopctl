defmodule LoopctlWeb.KnowledgeStatsController do
  @moduledoc """
  Controller for the lightweight knowledge stats endpoint.

  - `GET /api/v1/knowledge/stats` -- tenant-wide article counts (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/stats` -- project-scoped counts (agent+)

  Returns aggregate `COUNT(*)` totals (no article rows or metadata), so a caller
  can answer "how many articles are here?" without paging the index. Counts
  span all statuses; `by_status` makes the published/draft/etc. split explicit.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:stats,
    summary: "Knowledge stats",
    description:
      "Returns aggregate article counts for the tenant — `total`, `by_category`, " <>
        "and `by_status` — computed with cheap COUNT(*) GROUP BY queries (no " <>
        "article metadata is loaded). Counts span all statuses (draft, published, " <>
        "archived, superseded); use `by_status` to see the split. When called via " <>
        "GET /projects/:project_id/knowledge/stats, counts both tenant-wide and " <>
        "project-specific articles (same visibility as the index). Role: agent+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped counts)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Knowledge stats", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             total: %OpenApiSpex.Schema{type: :integer},
             by_category: %OpenApiSpex.Schema{
               type: :object,
               description: "Count per category"
             },
             by_status: %OpenApiSpex.Schema{
               type: :object,
               description: "Count per status"
             }
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/stats or GET /api/v1/projects/:project_id/knowledge/stats"
  def stats(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      case params["project_id"] do
        nil -> []
        "" -> []
        project_id -> [project_id: project_id]
      end

    result = Knowledge.stats(tenant_id, opts)
    json(conn, LoopctlWeb.KnowledgeStatsJSON.stats(result))
  end
end
