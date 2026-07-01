defmodule LoopctlWeb.WelcomeController do
  @moduledoc """
  API root welcome endpoint.

  GET /api/v1/ -- returns discovery links to the OpenAPI spec, Swagger UI, health,
  the RFC 8615 discovery document, the route index, the public wiki, and the MCP
  server (the recommended interface for AI coding agents).
  Public endpoint, no authentication required.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  tags(["Discovery"])

  operation(:index,
    summary: "API discovery endpoint",
    description: "Returns links to the OpenAPI spec, Swagger UI, and health check.",
    security: [],
    responses: %{
      200 =>
        {"Welcome response", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             name: %OpenApiSpex.Schema{type: :string, example: "loopctl"},
             version: %OpenApiSpex.Schema{type: :string, example: "1.0.0"},
             docs: %OpenApiSpex.Schema{type: :string, example: "/api/v1/openapi"},
             swagger_ui: %OpenApiSpex.Schema{type: :string, example: "/swaggerui"},
             health: %OpenApiSpex.Schema{type: :string, example: "/health"},
             discovery: %OpenApiSpex.Schema{type: :string, example: "/.well-known/loopctl"},
             routes: %OpenApiSpex.Schema{type: :string, example: "/api/v1/routes"},
             wiki: %OpenApiSpex.Schema{type: :string, example: "/wiki"},
             mcp_server: %OpenApiSpex.Schema{
               type: :object,
               description: "Recommended interface for AI coding agents (no curl needed)",
               properties: %{
                 npm: %OpenApiSpex.Schema{type: :string, example: "loopctl-mcp-server"},
                 registry: %OpenApiSpex.Schema{
                   type: :string,
                   example: "https://www.npmjs.com/package/loopctl-mcp-server"
                 }
               }
             }
           }
         }}
    }
  )

  @doc """
  GET /api/v1/

  Returns a JSON discovery document with links to API documentation and health.
  """
  def index(conn, _params) do
    json(conn, %{
      name: "loopctl",
      version: to_string(Application.spec(:loopctl, :vsn)),
      docs: "/api/v1/openapi",
      swagger_ui: "/swaggerui",
      health: "/health",
      discovery: "/.well-known/loopctl",
      routes: "/api/v1/routes",
      wiki: "/wiki",
      mcp_server: %{
        npm: "loopctl-mcp-server",
        registry: "https://www.npmjs.com/package/loopctl-mcp-server"
      }
    })
  end
end
