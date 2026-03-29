defmodule LoopctlWeb.RouteDiscoveryController do
  @moduledoc """
  Returns a machine-readable list of all available API routes.

  Agents can call GET /api/v1/routes to discover the full API surface
  before probing endpoints blindly. Requires authentication so that
  route enumeration is tied to a valid API key.
  """

  use LoopctlWeb, :controller

  def index(conn, _params) do
    routes = [
      %{method: "GET", path: "/api/v1/routes", description: "This endpoint — list all routes"},
      %{method: "GET", path: "/api/v1/projects", description: "List projects"},
      %{method: "POST", path: "/api/v1/projects", description: "Create project"},
      %{method: "GET", path: "/api/v1/projects/:id", description: "Get project"},
      %{method: "PATCH", path: "/api/v1/projects/:id", description: "Update project"},
      %{method: "DELETE", path: "/api/v1/projects/:id", description: "Delete project"},
      %{method: "GET", path: "/api/v1/projects/:id/progress", description: "Project progress"},
      %{
        method: "POST",
        path: "/api/v1/projects/:id/import",
        description: "Import epics and stories"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:id/export",
        description: "Export project"
      },
      %{
        method: "GET",
        path: "/api/v1/stories",
        description:
          "List stories (requires project_id). Filters: agent_status, verified_status, epic_id, limit (alias: page_size), offset"
      },
      %{
        method: "GET",
        path: "/api/v1/stories/ready",
        description: "Stories ready for work (all dependencies met)"
      },
      %{
        method: "GET",
        path: "/api/v1/stories/blocked",
        description: "Stories blocked by unmet dependencies"
      },
      %{method: "GET", path: "/api/v1/stories/:id", description: "Get story details"},
      %{method: "PATCH", path: "/api/v1/stories/:id", description: "Update story metadata"},
      %{method: "DELETE", path: "/api/v1/stories/:id", description: "Delete story"},
      %{
        method: "POST",
        path: "/api/v1/stories/:id/contract",
        description: "Contract story (prove you read ACs — required before claiming)"
      },
      %{method: "POST", path: "/api/v1/stories/:id/claim", description: "Claim story"},
      %{
        method: "POST",
        path: "/api/v1/stories/:id/start",
        description: "Start implementation (alias: /start-work)"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/report",
        description: "Report done (alias: /report-done)"
      },
      %{method: "POST", path: "/api/v1/stories/:id/unclaim", description: "Unclaim story"},
      %{
        method: "POST",
        path: "/api/v1/stories/:id/verify",
        description: "Verify story (requires review_type + summary)"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/reject",
        description: "Reject story (requires reason)"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/artifacts",
        description: "Post artifact report for story"
      },
      %{method: "GET", path: "/api/v1/stories/:id/artifacts", description: "List artifacts"},
      %{method: "GET", path: "/api/v1/stories/:id/history", description: "Story audit history"},
      %{
        method: "POST",
        path: "/api/v1/stories/bulk/claim",
        description: "Bulk claim stories"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/bulk/verify",
        description: "Bulk verify stories"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/bulk/reject",
        description: "Bulk reject stories"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/bulk/mark-complete",
        description: "Mark multiple stories as verified (admin)"
      },
      %{
        method: "POST",
        path: "/api/v1/epics/:id/verify-all",
        description: "Verify all reported-done stories in epic"
      },
      %{
        method: "GET",
        path: "/api/v1/epics/:epic_id/stories",
        description:
          "List stories in epic. Filters: page, page_size (alias: limit), agent_status, verified_status"
      },
      %{
        method: "POST",
        path: "/api/v1/epics/:epic_id/stories",
        description: "Create story in epic"
      },
      %{method: "GET", path: "/api/v1/epics/:id", description: "Get epic"},
      %{method: "PATCH", path: "/api/v1/epics/:id", description: "Update epic"},
      %{method: "DELETE", path: "/api/v1/epics/:id", description: "Delete epic"},
      %{method: "GET", path: "/api/v1/epics/:id/progress", description: "Epic progress"},
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/epics",
        description: "List epics in project"
      },
      %{method: "GET", path: "/api/v1/tenants/me", description: "Current tenant info"},
      %{method: "PATCH", path: "/api/v1/tenants/me", description: "Update current tenant"},
      %{
        method: "GET",
        path: "/api/v1/audit",
        description: "Audit log for current tenant"
      },
      %{
        method: "GET",
        path: "/api/v1/changes",
        description: "Change feed (supports ?since= timestamp)"
      },
      %{
        method: "GET",
        path: "/api/v1/orchestrator/state/:project_id",
        description: "Get orchestrator checkpoint for project"
      },
      %{
        method: "PUT",
        path: "/api/v1/orchestrator/state/:project_id",
        description: "Save orchestrator checkpoint"
      },
      %{
        method: "GET",
        path: "/api/v1/orchestrator/state/:project_id/history",
        description: "Orchestrator checkpoint history"
      },
      %{
        method: "GET",
        path: "/api/v1/agents",
        description: "List registered agents"
      },
      %{
        method: "POST",
        path: "/api/v1/agents/register",
        description: "Register agent"
      },
      %{method: "GET", path: "/api/v1/agents/:id", description: "Get agent"},
      %{
        method: "GET",
        path: "/api/v1/api_keys",
        description: "List API keys for current tenant"
      },
      %{method: "POST", path: "/api/v1/api_keys", description: "Create API key"},
      %{method: "DELETE", path: "/api/v1/api_keys/:id", description: "Delete API key"},
      %{method: "POST", path: "/api/v1/api_keys/:id/rotate", description: "Rotate API key"},
      %{method: "GET", path: "/api/openapi", description: "Full OpenAPI 3.0 spec (Swagger)"},

      # UI Test Runs (project-level QA)
      %{
        method: "POST",
        path: "/api/v1/projects/:project_id/ui-tests",
        description: "Start a UI test run"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/ui-tests",
        description: "List UI test runs. Filters: status, limit, offset"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/ui-tests/:id",
        description: "Get UI test run with findings"
      },
      %{
        method: "POST",
        path: "/api/v1/projects/:project_id/ui-tests/:id/findings",
        description: "Add a finding to a UI test run"
      },
      %{
        method: "POST",
        path: "/api/v1/projects/:project_id/ui-tests/:id/complete",
        description: "Complete a UI test run (pass/fail)"
      }
    ]

    json(conn, %{routes: routes, count: length(routes)})
  end
end
