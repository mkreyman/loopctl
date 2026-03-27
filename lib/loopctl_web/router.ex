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
  end

  # Health check — unauthenticated, outside /api/v1
  scope "/", LoopctlWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # Public API endpoints (no auth required)
  scope "/api/v1", LoopctlWeb do
    pipe_through :api
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through [:api, :authenticated]
  end
end
