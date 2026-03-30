defmodule LoopctlWeb.Router do
  use LoopctlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: Loopctl.ApiSpec
  end

  pipeline :authenticated do
    plug LoopctlWeb.Plugs.ExtractApiKey
    plug LoopctlWeb.Plugs.ResolveApiKey
    plug LoopctlWeb.Plugs.SetTenant
    plug LoopctlWeb.Plugs.RequireAuth
    plug LoopctlWeb.Plugs.Impersonate
    plug LoopctlWeb.Plugs.RateLimiter
    plug LoopctlWeb.Plugs.UpdateLastSeen
  end

  pipeline :registration_rate_limit do
    plug LoopctlWeb.Plugs.RegistrationRateLimiter
  end

  # Health check and root redirect — unauthenticated, outside /api/v1
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/", WelcomeController, :redirect_to_api
    get "/health", HealthController, :check
  end

  # OpenAPI spec and Swagger UI — only available in dev/test
  if Application.compile_env(:loopctl, :dev_routes, false) do
    scope "/api/v1" do
      pipe_through [:api]

      get "/openapi", OpenApiSpex.Plug.RenderSpec, []
      get "/", LoopctlWeb.WelcomeController, :index
    end

    scope "/swaggerui" do
      get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/v1/openapi"
    end
  else
    scope "/api/v1" do
      pipe_through [:api]

      get "/", LoopctlWeb.WelcomeController, :index
    end
  end

  # Public API endpoints (no auth required)
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :registration_rate_limit]

    post "/tenants/register", TenantController, :register
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :authenticated]

    get "/routes", RouteDiscoveryController, :index

    get "/tenants/me", TenantController, :show
    patch "/tenants/me", TenantController, :update

    # API key management
    resources "/api_keys", ApiKeyController, only: [:create, :index, :delete]
    post "/api_keys/:id/rotate", ApiKeyController, :rotate

    # Audit log
    get "/audit", AuditController, :index

    # Change feed
    get "/changes", ChangeController, :index

    # Dependency graph queries (must be before stories/:id to avoid matching "ready"/"blocked")
    get "/stories/ready", DependencyGraphController, :ready
    get "/stories/blocked", DependencyGraphController, :blocked

    # Project-scoped story listing (must be before stories/:id to avoid route conflicts)
    get "/stories", StoryController, :index_by_project

    # Bulk operations (Epic 13) — must be before stories/:id to avoid route conflicts
    post "/stories/bulk/claim", BulkOperationsController, :claim
    post "/stories/bulk/verify", BulkOperationsController, :verify
    post "/stories/bulk/reject", BulkOperationsController, :reject
    post "/stories/bulk/mark-complete", BulkOperationsController, :mark_complete

    # Story history
    get "/stories/:id/history", StoryHistoryController, :show

    # Story status transitions (agent side of two-tier trust model)
    post "/stories/:id/contract", StoryStatusController, :contract
    post "/stories/:id/claim", StoryStatusController, :claim
    post "/stories/:id/start", StoryStatusController, :start
    post "/stories/:id/request-review", StoryStatusController, :request_review
    post "/stories/:id/report", StoryStatusController, :report
    post "/stories/:id/unclaim", StoryStatusController, :unclaim
    # Discoverability aliases — same actions, alternate URL patterns agents tend to guess
    post "/stories/:id/report-done", StoryStatusController, :report
    post "/stories/:id/start-work", StoryStatusController, :start

    # Artifact reports (Epic 8)
    post "/stories/:id/artifacts", ArtifactReportController, :create
    get "/stories/:id/artifacts", ArtifactReportController, :index

    # Review pipeline completion (must precede verify)
    post "/stories/:id/review-complete", ReviewRecordController, :create

    # Story verification (orchestrator side of two-tier trust model)
    post "/stories/:id/verify", StoryVerificationController, :verify
    post "/stories/:id/reject", StoryVerificationController, :reject
    get "/stories/:story_id/verifications", StoryVerificationController, :index
    post "/stories/:id/force-unclaim", StoryVerificationController, :force_unclaim

    # Bulk epic verification (orchestrator convenience)
    post "/epics/:id/verify-all", StoryVerificationController, :verify_all

    # Agent management
    post "/agents/register", AgentController, :register
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show

    # Project management
    resources "/projects", ProjectController, only: [:create, :index, :show, :update, :delete]
    get "/projects/:id/progress", ProjectController, :progress

    # Import/Export (Epic 12)
    post "/projects/:id/import", ImportExportController, :import_project
    get "/projects/:id/export", ImportExportController, :export_project

    # UI Test Runs
    post "/projects/:project_id/ui-tests", UiTestController, :create
    get "/projects/:project_id/ui-tests", UiTestController, :index
    get "/projects/:project_id/ui-tests/:id", UiTestController, :show
    post "/projects/:project_id/ui-tests/:id/findings", UiTestController, :add_finding
    post "/projects/:project_id/ui-tests/:id/complete", UiTestController, :complete

    # Epic management
    get "/projects/:project_id/epics", EpicController, :index
    post "/projects/:project_id/epics", EpicController, :create
    get "/epics/:id", EpicController, :show
    patch "/epics/:id", EpicController, :update
    delete "/epics/:id", EpicController, :delete
    get "/epics/:id/progress", EpicController, :progress

    # Story management
    get "/epics/:epic_id/stories", StoryController, :index
    post "/epics/:epic_id/stories", StoryController, :create
    get "/stories/:id", StoryController, :show
    patch "/stories/:id", StoryController, :update
    delete "/stories/:id", StoryController, :delete

    # Dependency graph
    get "/projects/:id/dependency_graph", DependencyGraphController, :graph

    # Epic dependencies
    post "/epic_dependencies", EpicDependencyController, :create
    delete "/epic_dependencies/:id", EpicDependencyController, :delete
    get "/projects/:id/epic_dependencies", EpicDependencyController, :index

    # Story dependencies
    post "/story_dependencies", StoryDependencyController, :create
    delete "/story_dependencies/:id", StoryDependencyController, :delete
    get "/epics/:id/story_dependencies", StoryDependencyController, :index

    # Orchestrator state
    put "/orchestrator/state/:project_id", OrchestratorStateController, :save
    get "/orchestrator/state/:project_id/history", OrchestratorStateController, :history
    get "/orchestrator/state/:project_id", OrchestratorStateController, :show

    # Webhooks (Epic 10)
    resources "/webhooks", WebhookController, only: [:create, :index, :update, :delete]
    post "/webhooks/:id/test", WebhookController, :test
    get "/webhooks/:id/deliveries", WebhookController, :deliveries

    # Skills (Epic 15)
    resources "/skills", SkillController, only: [:create, :index, :show, :update, :delete]
    # Literal paths must come before parameterized paths to avoid shadowing
    post "/skills/import", SkillController, :import_skills
    post "/skills/:id/versions", SkillController, :create_version
    get "/skills/:id/versions", SkillController, :list_versions
    get "/skills/:id/versions/:version", SkillController, :get_version
    get "/skills/:id/stats", SkillController, :stats
    get "/skills/:id/versions/:version/results", SkillController, :version_results

    # Skill results
    post "/skill_results", SkillResultController, :create
  end

  # Superadmin endpoints (Epic 11)
  scope "/api/v1/admin", LoopctlWeb do
    pipe_through [:api, :authenticated]

    # Tenant management
    get "/tenants", AdminTenantController, :index
    get "/tenants/:id", AdminTenantController, :show
    patch "/tenants/:id", AdminTenantController, :update
    post "/tenants/:id/suspend", AdminTenantController, :suspend
    post "/tenants/:id/activate", AdminTenantController, :activate

    # System-wide stats
    get "/stats", AdminStatsController, :show

    # Cross-tenant audit log
    get "/audit", AdminAuditController, :index
  end
end
