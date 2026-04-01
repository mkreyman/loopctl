defmodule LoopctlWeb.WelcomeController do
  @moduledoc """
  API root welcome endpoint.

  GET /api/v1/ -- returns discovery links to docs, health, and Swagger UI.
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
             version: %OpenApiSpex.Schema{type: :string, example: "0.1.0"},
             docs: %OpenApiSpex.Schema{type: :string, example: "/api/v1/openapi"},
             swagger_ui: %OpenApiSpex.Schema{type: :string, example: "/swaggerui"},
             health: %OpenApiSpex.Schema{type: :string, example: "/health"}
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
      version: "0.1.0",
      docs: "/api/v1/openapi",
      swagger_ui: "/swaggerui",
      health: "/health"
    })
  end
end
