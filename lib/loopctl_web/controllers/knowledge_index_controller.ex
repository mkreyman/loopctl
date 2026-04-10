defmodule LoopctlWeb.KnowledgeIndexController do
  @moduledoc """
  Controller for the lightweight knowledge catalog endpoint.

  - `GET /api/v1/knowledge/index` -- tenant-wide catalog of published articles (agent+)
  - `GET /api/v1/projects/:project_id/knowledge/index` -- project-scoped catalog (agent+)

  Returns article metadata (no body) grouped by category, capped at 1000 articles.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:index,
    summary: "Knowledge index",
    description:
      "Returns a lightweight catalog of published articles grouped by category. " <>
        "Each article includes only id, title, category, tags, status, and updated_at. " <>
        "When called via GET /projects/:project_id/knowledge/index, includes both " <>
        "tenant-wide and project-specific articles. Capped at 1000 articles. " <>
        "Role: agent+.",
    parameters: [
      project_id: [
        in: :path,
        type: :string,
        description: "Project UUID (optional, for project-scoped index)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Knowledge index", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{
               type: :object,
               description: "Articles grouped by category"
             },
             meta: %OpenApiSpex.Schema{
               type: :object,
               properties: %{
                 total_count: %OpenApiSpex.Schema{type: :integer},
                 categories: %OpenApiSpex.Schema{type: :object},
                 truncated: %OpenApiSpex.Schema{type: :boolean}
               }
             }
           }
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/index or GET /api/v1/projects/:project_id/knowledge/index"
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      case params["project_id"] do
        nil -> []
        project_id -> [project_id: project_id]
      end

    {:ok, result} = Knowledge.list_index(tenant_id, opts)

    json(conn, LoopctlWeb.KnowledgeIndexJSON.index(result))
  end
end
