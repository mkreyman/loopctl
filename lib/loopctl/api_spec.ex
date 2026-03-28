defmodule Loopctl.ApiSpec do
  @moduledoc """
  Root OpenAPI 3.0 specification module for loopctl.

  Implements `OpenApiSpex.OpenApi` behaviour to auto-generate the
  API specification from controller annotations.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "loopctl",
        version: "0.1.0",
        description:
          "Agent-native project state store for AI development loops. " <>
            "Provides multi-tenant project management, work breakdown, " <>
            "two-tier trust model for story verification, and orchestrator state."
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(LoopctlWeb.Router),
      components: %Components{
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "API key obtained from tenant registration (POST /api/v1/tenants/register)"
          }
        }
      },
      security: [%{"BearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
