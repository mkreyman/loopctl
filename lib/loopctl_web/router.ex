defmodule LoopctlWeb.Router do
  use LoopctlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LoopctlWeb do
    pipe_through :api
  end
end
