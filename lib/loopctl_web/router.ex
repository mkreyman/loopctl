defmodule LoopctlWeb.Router do
  use LoopctlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug LoopctlWeb.Plugs.ExtractApiKey
    plug LoopctlWeb.Plugs.ResolveApiKey
    plug LoopctlWeb.Plugs.SetTenant
    plug LoopctlWeb.Plugs.RequireAuth
    plug LoopctlWeb.Plugs.RateLimiter
    plug LoopctlWeb.Plugs.UpdateLastSeen
  end

  pipeline :registration_rate_limit do
    plug LoopctlWeb.Plugs.RegistrationRateLimiter
  end

  # Health check — unauthenticated, outside /api/v1
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # Public API endpoints (no auth required)
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :registration_rate_limit]

    post "/tenants/register", TenantController, :register
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :authenticated]

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

    # Story history
    get "/stories/:id/history", StoryHistoryController, :show

    # Story status transitions (agent side of two-tier trust model)
    post "/stories/:id/contract", StoryStatusController, :contract
    post "/stories/:id/claim", StoryStatusController, :claim
    post "/stories/:id/start", StoryStatusController, :start
    post "/stories/:id/report", StoryStatusController, :report
    post "/stories/:id/unclaim", StoryStatusController, :unclaim

    # Artifact reports (Epic 8)
    post "/stories/:id/artifacts", ArtifactReportController, :create
    get "/stories/:id/artifacts", ArtifactReportController, :index

    # Story verification (orchestrator side of two-tier trust model)
    post "/stories/:id/verify", StoryVerificationController, :verify
    post "/stories/:id/reject", StoryVerificationController, :reject
    get "/stories/:story_id/verifications", StoryVerificationController, :index
    post "/stories/:id/force-unclaim", StoryVerificationController, :force_unclaim

    # Agent management
    post "/agents/register", AgentController, :register
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show

    # Project management
    resources "/projects", ProjectController, only: [:create, :index, :show, :update, :delete]
    get "/projects/:id/progress", ProjectController, :progress

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
  end
end
