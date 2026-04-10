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
      # Route discovery
      %{method: "GET", path: "/api/v1/routes", description: "This endpoint — list all routes"},

      # Tenant management
      %{method: "GET", path: "/api/v1/tenants/me", description: "Current tenant info"},
      %{
        method: "PATCH",
        path: "/api/v1/tenants/me",
        description: "Update current tenant (settings.knowledge_auto_extract, etc.)"
      },

      # API key management
      %{
        method: "GET",
        path: "/api/v1/api_keys",
        description: "List API keys for current tenant"
      },
      %{method: "POST", path: "/api/v1/api_keys", description: "Create API key"},
      %{method: "DELETE", path: "/api/v1/api_keys/:id", description: "Delete API key"},
      %{method: "POST", path: "/api/v1/api_keys/:id/rotate", description: "Rotate API key"},

      # Audit & change feed
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

      # Agent management
      %{method: "POST", path: "/api/v1/agents/register", description: "Register agent"},
      %{method: "GET", path: "/api/v1/agents", description: "List registered agents"},
      %{method: "GET", path: "/api/v1/agents/:id", description: "Get agent"},

      # Project management
      %{method: "GET", path: "/api/v1/projects", description: "List projects"},
      %{method: "POST", path: "/api/v1/projects", description: "Create project"},
      %{method: "GET", path: "/api/v1/projects/:id", description: "Get project"},
      %{method: "PATCH", path: "/api/v1/projects/:id", description: "Update project"},
      %{method: "DELETE", path: "/api/v1/projects/:id", description: "Delete project"},
      %{method: "GET", path: "/api/v1/projects/:id/progress", description: "Project progress"},

      # Import/Export
      %{
        method: "POST",
        path: "/api/v1/projects/:id/import",
        description: "Import epics and stories (orchestrator, user, or superadmin role)"
      },
      %{method: "GET", path: "/api/v1/projects/:id/export", description: "Export project"},

      # Epic management
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/epics",
        description: "List epics in project"
      },
      %{
        method: "POST",
        path: "/api/v1/projects/:project_id/epics",
        description: "Create epic in project"
      },
      %{method: "GET", path: "/api/v1/epics/:id", description: "Get epic"},
      %{method: "PATCH", path: "/api/v1/epics/:id", description: "Update epic"},
      %{method: "DELETE", path: "/api/v1/epics/:id", description: "Delete epic"},
      %{method: "GET", path: "/api/v1/epics/:id/progress", description: "Epic progress"},

      # Story management
      %{
        method: "GET",
        path: "/api/v1/stories",
        description:
          "List stories (requires project_id). Filters: agent_status, verified_status, epic_id, limit (alias: page_size), offset"
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
      %{method: "GET", path: "/api/v1/stories/:id", description: "Get story details"},
      %{method: "PATCH", path: "/api/v1/stories/:id", description: "Update story metadata"},
      %{method: "DELETE", path: "/api/v1/stories/:id", description: "Delete story"},

      # Dependency graph
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
      %{
        method: "GET",
        path: "/api/v1/projects/:id/dependency_graph",
        description: "Full dependency graph for project (epics and stories)"
      },

      # Epic dependencies
      %{
        method: "POST",
        path: "/api/v1/epic_dependencies",
        description: "Create epic dependency"
      },
      %{
        method: "DELETE",
        path: "/api/v1/epic_dependencies/:id",
        description: "Delete epic dependency"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:id/epic_dependencies",
        description: "List epic dependencies for project"
      },

      # Story dependencies
      %{
        method: "POST",
        path: "/api/v1/story_dependencies",
        description: "Create story dependency"
      },
      %{
        method: "DELETE",
        path: "/api/v1/story_dependencies/:id",
        description: "Delete story dependency"
      },
      %{
        method: "GET",
        path: "/api/v1/epics/:id/story_dependencies",
        description: "List story dependencies for epic"
      },

      # Story status transitions
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
        path: "/api/v1/stories/:id/start-work",
        description: "Alias for /start"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/request-review",
        description:
          "Signal implementation is ready for review (assigned agent only). " <>
            "Fires story.review_requested webhook. Does NOT change status."
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/report",
        description:
          "Confirm implementation done (chain-of-custody: caller must be a DIFFERENT agent from implementer)"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/report-done",
        description: "Alias for /report"
      },
      %{method: "POST", path: "/api/v1/stories/:id/unclaim", description: "Unclaim story"},

      # Review pipeline
      %{
        method: "POST",
        path: "/api/v1/stories/:id/review-complete",
        description:
          "Record review completion (call AFTER reported_done, BEFORE verify). " <>
            "Required params: review_type. Optional: findings_count, fixes_count, summary, completed_at."
      },

      # Story verification
      %{
        method: "POST",
        path: "/api/v1/stories/:id/verify",
        description:
          "Verify story (requires a review_record — call /review-complete first). " <>
            "Optional params: summary, findings, result, review_type."
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/reject",
        description: "Reject story (requires reason)"
      },
      %{
        method: "GET",
        path: "/api/v1/stories/:story_id/verifications",
        description: "List verifications for story"
      },
      %{
        method: "POST",
        path: "/api/v1/stories/:id/force-unclaim",
        description: "Force-unclaim a story (orchestrator/user only)"
      },

      # Artifact reports
      %{
        method: "POST",
        path: "/api/v1/stories/:id/artifacts",
        description: "Post artifact report for story"
      },
      %{method: "GET", path: "/api/v1/stories/:id/artifacts", description: "List artifacts"},

      # Story history
      %{method: "GET", path: "/api/v1/stories/:id/history", description: "Story audit history"},

      # Bulk operations
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

      # Orchestrator state
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

      # Webhooks
      %{method: "POST", path: "/api/v1/webhooks", description: "Create webhook subscription"},
      %{method: "GET", path: "/api/v1/webhooks", description: "List webhook subscriptions"},
      %{method: "PATCH", path: "/api/v1/webhooks/:id", description: "Update webhook"},
      %{method: "DELETE", path: "/api/v1/webhooks/:id", description: "Delete webhook"},
      %{
        method: "POST",
        path: "/api/v1/webhooks/:id/test",
        description: "Send test delivery to webhook"
      },
      %{
        method: "GET",
        path: "/api/v1/webhooks/:id/deliveries",
        description: "List webhook delivery history"
      },

      # Skills
      %{method: "POST", path: "/api/v1/skills", description: "Create skill"},
      %{method: "GET", path: "/api/v1/skills", description: "List skills"},
      %{method: "GET", path: "/api/v1/skills/:id", description: "Get skill"},
      %{method: "PATCH", path: "/api/v1/skills/:id", description: "Update skill"},
      %{method: "DELETE", path: "/api/v1/skills/:id", description: "Delete skill"},
      %{
        method: "POST",
        path: "/api/v1/skills/import",
        description: "Bulk import skills from external source"
      },
      %{
        method: "POST",
        path: "/api/v1/skills/:id/versions",
        description: "Create skill version"
      },
      %{
        method: "GET",
        path: "/api/v1/skills/:id/versions",
        description: "List skill versions"
      },
      %{
        method: "GET",
        path: "/api/v1/skills/:id/versions/:version",
        description: "Get specific skill version"
      },
      %{
        method: "GET",
        path: "/api/v1/skills/:id/stats",
        description: "Skill usage statistics"
      },
      %{
        method: "GET",
        path: "/api/v1/skills/:id/versions/:version/results",
        description: "Results for specific skill version"
      },
      %{
        method: "GET",
        path: "/api/v1/skills/:id/cost-performance",
        description: "Skill cost performance (token usage per version)"
      },

      # Skill results
      %{method: "POST", path: "/api/v1/skill_results", description: "Record skill result"},

      # Token usage
      %{method: "POST", path: "/api/v1/token-usage", description: "Report token usage"},
      %{
        method: "DELETE",
        path: "/api/v1/token-usage/:id",
        description: "Delete token usage record"
      },
      %{
        method: "POST",
        path: "/api/v1/token-usage/:id/correction",
        description: "Submit correction for token usage record"
      },
      %{
        method: "GET",
        path: "/api/v1/stories/:story_id/token-usage",
        description: "List token usage for story"
      },

      # Token budgets
      %{method: "POST", path: "/api/v1/token-budgets", description: "Create token budget"},
      %{method: "GET", path: "/api/v1/token-budgets", description: "List token budgets"},
      %{method: "GET", path: "/api/v1/token-budgets/:id", description: "Get token budget"},
      %{method: "PATCH", path: "/api/v1/token-budgets/:id", description: "Update token budget"},
      %{
        method: "DELETE",
        path: "/api/v1/token-budgets/:id",
        description: "Delete token budget"
      },

      # Cost anomalies
      %{
        method: "GET",
        path: "/api/v1/cost-anomalies",
        description: "List cost anomalies. Filters: status, severity, agent_id, project_id"
      },
      %{
        method: "PATCH",
        path: "/api/v1/cost-anomalies/:id",
        description: "Update cost anomaly (resolve, dismiss, etc.)"
      },

      # Token analytics
      %{
        method: "GET",
        path: "/api/v1/analytics/agents",
        description: "Per-agent token usage analytics"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/epics",
        description: "Per-epic token usage analytics"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/projects/:id",
        description: "Project-level token analytics"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/models",
        description: "Per-model token usage analytics"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/trends",
        description: "Token usage trends over time"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/model-mix",
        description: "Model mix breakdown across agents/projects"
      },
      %{
        method: "GET",
        path: "/api/v1/analytics/agents/:id/model-profile",
        description: "Model usage profile for specific agent"
      },

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
      },

      # Knowledge Wiki — articles
      %{method: "GET", path: "/api/v1/articles", description: "List articles"},
      %{method: "POST", path: "/api/v1/articles", description: "Create article"},
      %{method: "GET", path: "/api/v1/articles/:id", description: "Get article"},
      %{method: "PATCH", path: "/api/v1/articles/:id", description: "Update article"},
      %{method: "DELETE", path: "/api/v1/articles/:id", description: "Delete article"},

      # Knowledge Wiki — publish workflow
      %{
        method: "POST",
        path: "/api/v1/articles/:id/publish",
        description: "Publish a draft article"
      },
      %{
        method: "POST",
        path: "/api/v1/articles/:id/unpublish",
        description: "Unpublish an article (revert to draft)"
      },
      %{
        method: "POST",
        path: "/api/v1/articles/:id/archive",
        description: "Archive an article"
      },
      %{
        method: "POST",
        path: "/api/v1/knowledge/bulk-publish",
        description: "Publish multiple draft articles at once"
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/drafts",
        description: "List draft articles awaiting review"
      },

      # Knowledge Wiki — search, context, index, export
      %{
        method: "GET",
        path: "/api/v1/knowledge/index",
        description: "Lightweight catalog of published articles"
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/search",
        description:
          "Unified knowledge search. Params: q, mode (keyword|semantic|combined), limit, offset"
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/context",
        description: "Deep-read context with recency scoring and linked refs (agent consumption)"
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/export",
        description: "Export wiki as Obsidian-compatible ZIP"
      },

      # Knowledge Wiki — lint and pipeline
      %{
        method: "GET",
        path: "/api/v1/knowledge/lint",
        description: "Knowledge wiki health check. Params: stale_days, min_links"
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/pipeline",
        description: "Self-learning pipeline status (extraction health, publish rates)"
      },

      # Knowledge Ingestion
      %{
        method: "POST",
        path: "/api/v1/knowledge/ingest",
        description:
          "Submit URL or raw content for knowledge extraction. " <>
            "Params: url (or content), source_type (required), project_id (optional)"
      },
      %{
        method: "POST",
        path: "/api/v1/knowledge/ingest/batch",
        description:
          "Batch-submit up to 50 ingestion items in a single request. " <>
            "Each item has the same shape as /knowledge/ingest. Returns per-item results."
      },
      %{
        method: "GET",
        path: "/api/v1/knowledge/ingestion-jobs",
        description: "List recent ingestion jobs (last 7 days, max 50)"
      },

      # Knowledge Wiki — project-scoped
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/articles",
        description: "List articles scoped to project"
      },
      %{
        method: "POST",
        path: "/api/v1/projects/:project_id/articles",
        description: "Create article in project"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/knowledge/index",
        description: "Project-scoped knowledge index"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/knowledge/export",
        description: "Project-scoped knowledge export"
      },
      %{
        method: "GET",
        path: "/api/v1/projects/:project_id/knowledge/lint",
        description: "Project-scoped knowledge lint"
      },

      # Article links
      %{
        method: "POST",
        path: "/api/v1/article_links",
        description: "Create link between articles"
      },
      %{
        method: "DELETE",
        path: "/api/v1/article_links/:id",
        description: "Delete article link"
      },
      %{
        method: "GET",
        path: "/api/v1/articles/:article_id/links",
        description: "List links for article"
      },

      # OpenAPI spec
      %{method: "GET", path: "/api/openapi", description: "Full OpenAPI 3.0 spec (Swagger)"},

      # Superadmin endpoints
      %{
        method: "GET",
        path: "/api/v1/admin/tenants",
        description: "List all tenants (superadmin only)"
      },
      %{
        method: "GET",
        path: "/api/v1/admin/tenants/:id",
        description: "Get tenant details (superadmin only)"
      },
      %{
        method: "PATCH",
        path: "/api/v1/admin/tenants/:id",
        description: "Update tenant (superadmin only)"
      },
      %{
        method: "POST",
        path: "/api/v1/admin/tenants/:id/suspend",
        description: "Suspend tenant (superadmin only)"
      },
      %{
        method: "POST",
        path: "/api/v1/admin/tenants/:id/activate",
        description: "Activate tenant (superadmin only)"
      },
      %{
        method: "GET",
        path: "/api/v1/admin/stats",
        description: "System-wide statistics (superadmin only)"
      },
      %{
        method: "GET",
        path: "/api/v1/admin/audit",
        description: "Cross-tenant audit log (superadmin only)"
      }
    ]

    json(conn, %{routes: routes, count: length(routes)})
  end
end
