defmodule Loopctl.ApiSpec do
  @moduledoc """
  Root OpenAPI 3.0 specification module for loopctl.

  Implements `OpenApiSpex.OpenApi` behaviour to auto-generate the
  API specification from controller annotations.
  """

  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Paths,
    Response,
    SecurityScheme,
    Server,
    Tag
  }

  alias Loopctl.ApiSpec.Schemas

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
      servers: [
        %Server{url: "/", description: "Current server"},
        %Server{url: "http://localhost:4000", description: "Local development"},
        %Server{url: "https://loopctl.local:8443", description: "Docker/Beelink deployment"}
      ],
      tags: [
        %Tag{name: "Discovery", description: "API discovery and health"},
        %Tag{name: "Health", description: "Health check endpoints"},
        %Tag{name: "Tenants", description: "Tenant registration and management"},
        %Tag{name: "Auth", description: "API key management"},
        %Tag{name: "Projects", description: "Project CRUD"},
        %Tag{name: "Epics", description: "Epic CRUD within projects"},
        %Tag{name: "Stories", description: "Story CRUD within epics"},
        %Tag{
          name: "Progress",
          description: "Two-tier story status management (contract/claim/verify)"
        },
        %Tag{
          name: "Dependencies",
          description: "Epic and story dependency management with cycle detection"
        },
        %Tag{name: "Artifacts", description: "Artifact reports and verification results"},
        %Tag{name: "Agents", description: "Agent registration and listing"},
        %Tag{name: "Orchestrator", description: "Orchestrator state checkpointing"},
        %Tag{name: "Webhooks", description: "Webhook subscriptions and delivery"},
        %Tag{name: "Import/Export", description: "Bulk import/export of project data"},
        %Tag{name: "Skills", description: "Skill versioning and performance tracking"},
        %Tag{name: "Admin", description: "Superadmin tenant management and system stats"},
        %Tag{name: "Audit", description: "Immutable audit log and change feed"}
      ],
      paths: Paths.from_router(LoopctlWeb.Router),
      components: %Components{
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "API key obtained from tenant registration (POST /api/v1/tenants/register)"
          }
        },
        responses: %{
          "RateLimitError" => %Response{
            description: "Rate limit exceeded. Check Retry-After header for reset time.",
            content: %{
              "application/json" => %MediaType{schema: Schemas.RateLimitError}
            }
          }
        }
      },
      security: [%{"BearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
