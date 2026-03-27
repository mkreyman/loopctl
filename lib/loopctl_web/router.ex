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

    # Story history
    get "/stories/:id/history", StoryHistoryController, :show

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
  end
end
