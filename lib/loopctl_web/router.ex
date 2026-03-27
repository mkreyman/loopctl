defmodule LoopctlWeb.Router do
  use LoopctlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check — unauthenticated, outside /api/v1
  scope "/", LoopctlWeb do
    pipe_through :api
  end

  # API v1 — all authenticated endpoints
  scope "/api/v1", LoopctlWeb do
    pipe_through :api
  end
end
