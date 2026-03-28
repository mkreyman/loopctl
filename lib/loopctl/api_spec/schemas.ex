defmodule Loopctl.ApiSpec.Schemas do
  @moduledoc """
  Reusable OpenAPI schema definitions for loopctl API request/response shapes.
  """

  alias OpenApiSpex.Schema

  # ---------- Shared / Reusable ----------

  defmodule ErrorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Standard error envelope",
      type: :object,
      required: [:error],
      properties: %{
        error: %Schema{
          type: :object,
          required: [:status, :message],
          properties: %{
            status: %Schema{type: :integer, description: "HTTP status code", example: 422},
            message: %Schema{
              type: :string,
              description: "Human-readable message",
              example: "Validation failed"
            },
            details: %Schema{
              type: :object,
              description: "Field-level error details (optional)",
              additionalProperties: true
            }
          }
        }
      },
      example: %{
        error: %{
          status: 404,
          message: "Not found"
        }
      }
    })
  end

  defmodule PaginationMeta do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PaginationMeta",
      description: "Pagination metadata returned by list endpoints",
      type: :object,
      properties: %{
        page: %Schema{type: :integer, example: 1},
        page_size: %Schema{type: :integer, example: 20},
        total_count: %Schema{type: :integer, example: 42},
        total_pages: %Schema{type: :integer, example: 3}
      }
    })
  end

  defmodule UuidId do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UuidId",
      description: "UUID v4 identifier",
      type: :string,
      format: :uuid,
      example: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    })
  end

  # ---------- Tenants ----------

  defmodule TenantResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TenantResponse",
      description: "Tenant profile",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        email: %Schema{type: :string, format: :email},
        settings: %Schema{type: :object, additionalProperties: true},
        status: %Schema{type: :string, enum: ["active", "suspended", "deactivated"]},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule TenantRegistrationRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TenantRegistrationRequest",
      description: "Request body for tenant registration",
      type: :object,
      required: [:name, :slug, :email],
      properties: %{
        name: %Schema{type: :string, description: "Tenant display name", example: "My Org"},
        slug: %Schema{
          type: :string,
          description: "Unique slug (lowercase, hyphens)",
          example: "my-org"
        },
        email: %Schema{
          type: :string,
          format: :email,
          description: "Contact email",
          example: "admin@example.com"
        }
      },
      example: %{name: "My Org", slug: "my-org", email: "admin@example.com"}
    })
  end

  defmodule TenantRegistrationResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TenantRegistrationResponse",
      description: "Response from tenant registration, includes the raw API key (shown once)",
      type: :object,
      properties: %{
        tenant: TenantResponse,
        api_key: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            raw_key: %Schema{
              type: :string,
              description: "The raw API key (shown only once)",
              example: "lc_abc123def456..."
            },
            key_prefix: %Schema{type: :string, example: "lc_abc1"},
            role: %Schema{type: :string, example: "user"},
            name: %Schema{type: :string, example: "default"}
          }
        }
      },
      example: %{
        tenant: %{
          id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
          name: "My Org",
          slug: "my-org",
          email: "admin@example.com",
          status: "active"
        },
        api_key: %{
          id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
          raw_key: "lc_abc123def456...",
          key_prefix: "lc_abc1",
          role: "user",
          name: "default"
        }
      }
    })
  end

  # ---------- API Keys ----------

  defmodule ApiKeyCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyCreateRequest",
      description: "Request body for creating an API key",
      type: :object,
      required: [:name, :role],
      properties: %{
        name: %Schema{type: :string},
        role: %Schema{type: :string, enum: ["user", "orchestrator", "agent"]},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Optional expiration"
        },
        agent_id: %Schema{type: :string, format: :uuid, description: "Optional linked agent"}
      }
    })
  end

  defmodule ApiKeyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyResponse",
      description: "API key (list view, no raw key)",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        key_prefix: %Schema{type: :string},
        role: %Schema{type: :string},
        last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Projects ----------

  defmodule ProjectCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ProjectCreateRequest",
      description: "Request body for creating a project",
      type: :object,
      required: [:name, :slug],
      properties: %{
        name: %Schema{type: :string, example: "My Project"},
        slug: %Schema{type: :string, example: "my-project"},
        repo_url: %Schema{
          type: :string,
          nullable: true,
          example: "https://github.com/org/repo"
        },
        description: %Schema{type: :string, nullable: true},
        tech_stack: %Schema{type: :string, nullable: true, example: "elixir,phoenix"},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      example: %{
        name: "My Project",
        slug: "my-project",
        repo_url: "https://github.com/org/repo"
      }
    })
  end

  defmodule ProjectResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ProjectResponse",
      description: "Project resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        repo_url: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true},
        tech_stack: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["active", "archived"]},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Epics ----------

  defmodule EpicResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EpicResponse",
      description: "Epic resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        project_id: %Schema{type: :string, format: :uuid},
        number: %Schema{type: :integer},
        title: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        phase: %Schema{type: :string, nullable: true},
        position: %Schema{type: :integer},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Stories ----------

  defmodule StoryResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StoryResponse",
      description: "Story resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        project_id: %Schema{type: :string, format: :uuid},
        epic_id: %Schema{type: :string, format: :uuid},
        number: %Schema{type: :string, example: "US-2.1"},
        title: %Schema{type: :string, example: "Implement user authentication"},
        description: %Schema{type: :string, nullable: true},
        acceptance_criteria: %Schema{
          type: :array,
          items: %Schema{type: :object},
          nullable: true,
          example: [
            %{criterion: "Users can log in with email and password", met: false},
            %{criterion: "Invalid credentials return 401", met: false}
          ]
        },
        estimated_hours: %Schema{type: :number, nullable: true, example: 4.0},
        agent_status: %Schema{
          type: :string,
          enum: ["pending", "contracted", "assigned", "implementing", "reported_done"],
          example: "pending"
        },
        verified_status: %Schema{
          type: :string,
          enum: ["unverified", "verified", "rejected"],
          example: "unverified"
        },
        assigned_agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        assigned_at: %Schema{type: :string, format: :"date-time", nullable: true},
        reported_done_at: %Schema{type: :string, format: :"date-time", nullable: true},
        verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        rejected_at: %Schema{type: :string, format: :"date-time", nullable: true},
        rejection_reason: %Schema{type: :string, nullable: true},
        sort_key: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule StoryStatusResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StoryStatusResponse",
      description: "Story state after a status transition",
      type: :object,
      properties: %{
        story: %Schema{
          type: :object,
          description: "Updated story state",
          additionalProperties: true
        }
      }
    })
  end

  defmodule ContractRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ContractRequest",
      description: "Agent acknowledges story acceptance criteria",
      type: :object,
      required: [:story_title, :ac_count],
      properties: %{
        story_title: %Schema{
          type: :string,
          description: "Must match the story title exactly",
          example: "Implement user authentication"
        },
        ac_count: %Schema{
          type: :integer,
          description: "Must match the number of acceptance criteria",
          example: 8
        }
      },
      example: %{story_title: "Implement user authentication", ac_count: 8}
    })
  end

  # ---------- Artifacts ----------

  defmodule ArtifactReportRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ArtifactReportRequest",
      description: "Submit an artifact report for a story",
      type: :object,
      required: [:artifact_type, :path],
      properties: %{
        artifact_type: %Schema{
          type: :string,
          description: "Type of artifact (e.g. file, test, migration)"
        },
        path: %Schema{type: :string, description: "File path or identifier"},
        exists: %Schema{type: :boolean, description: "Whether the artifact exists"},
        details: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Additional details"
        }
      }
    })
  end

  defmodule VerificationResultResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerificationResultResponse",
      description: "Verification result record",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        result: %Schema{type: :string, enum: ["pass", "fail"]},
        reason: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Agents ----------

  defmodule AgentRegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentRegisterRequest",
      description: "Self-registration request for an agent",
      type: :object,
      required: [:name, :agent_type],
      properties: %{
        name: %Schema{type: :string},
        agent_type: %Schema{type: :string, enum: ["orchestrator", "implementer"]},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule AgentResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentResponse",
      description: "Agent resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        agent_type: %Schema{type: :string, enum: ["orchestrator", "implementer"]},
        status: %Schema{type: :string, enum: ["active", "idle", "deactivated"]},
        last_seen_at: %Schema{type: :string, format: :"date-time", nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Webhooks ----------

  defmodule WebhookCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookCreateRequest",
      description: "Create a webhook subscription",
      type: :object,
      required: [:url, :events],
      properties: %{
        url: %Schema{type: :string, format: :uri},
        events: %Schema{type: :array, items: %Schema{type: :string}},
        project_id: %Schema{type: :string, format: :uuid, nullable: true}
      }
    })
  end

  defmodule WebhookResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookResponse",
      description: "Webhook subscription resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        url: %Schema{type: :string},
        events: %Schema{type: :array, items: %Schema{type: :string}},
        project_id: %Schema{type: :string, format: :uuid, nullable: true},
        active: %Schema{type: :boolean},
        consecutive_failures: %Schema{type: :integer},
        last_delivery_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Orchestrator State ----------

  defmodule OrchestratorStateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OrchestratorStateRequest",
      description: "Save orchestrator state (upsert with optimistic locking)",
      type: :object,
      required: [:state_key, :state_data],
      properties: %{
        state_key: %Schema{type: :string, description: "State namespace key (default: 'main')"},
        state_data: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Arbitrary state payload"
        },
        version: %Schema{
          type: :integer,
          description: "Expected version for optimistic lock",
          nullable: true
        }
      }
    })
  end

  # ---------- Skills ----------

  defmodule SkillResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SkillResponse",
      description: "Skill resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        current_version: %Schema{type: :integer},
        status: %Schema{type: :string, enum: ["active", "archived"]},
        project_id: %Schema{type: :string, format: :uuid, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule SkillVersionResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SkillVersionResponse",
      description: "Skill version resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        skill_id: %Schema{type: :string, format: :uuid},
        version: %Schema{type: :integer},
        prompt_text: %Schema{type: :string},
        changelog: %Schema{type: :string, nullable: true},
        created_by: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  # ---------- Import/Export ----------

  defmodule ImportRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImportRequest",
      description: "Import work breakdown into a project",
      type: :object,
      required: [:epics],
      properties: %{
        epics: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true},
          description: "Array of epic objects with nested stories"
        },
        story_dependencies: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true},
          description: "Optional cross-story dependencies",
          nullable: true
        },
        epic_dependencies: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true},
          description: "Optional cross-epic dependencies",
          nullable: true
        }
      },
      example: %{
        epics: [
          %{
            number: 1,
            title: "User Authentication",
            description: "Auth infrastructure",
            stories: [
              %{
                number: "1.1",
                title: "Implement login endpoint",
                acceptance_criteria: [
                  %{criterion: "POST /login returns JWT on valid credentials"},
                  %{criterion: "Invalid credentials return 401"}
                ]
              },
              %{
                number: "1.2",
                title: "Implement logout endpoint",
                acceptance_criteria: [
                  %{criterion: "POST /logout invalidates the session"}
                ]
              }
            ]
          }
        ],
        story_dependencies: [
          %{story: "1.1", depends_on: "1.2"}
        ]
      }
    })
  end

  defmodule ExportResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportResponse",
      description: "Complete project export",
      type: :object,
      properties: %{
        project: %Schema{type: :object, additionalProperties: true},
        epics: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        dependencies: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  # ---------- Bulk Operations ----------

  defmodule BulkClaimRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BulkClaimRequest",
      description: "Bulk claim stories",
      type: :object,
      required: [:story_ids],
      properties: %{
        story_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          description: "Story IDs to claim (max 50)"
        }
      }
    })
  end

  defmodule BulkVerifyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BulkVerifyRequest",
      description: "Bulk verify stories",
      type: :object,
      required: [:stories],
      properties: %{
        stories: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              story_id: %Schema{type: :string, format: :uuid},
              notes: %Schema{type: :string, nullable: true}
            }
          }
        }
      }
    })
  end

  defmodule BulkRejectRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BulkRejectRequest",
      description: "Bulk reject stories",
      type: :object,
      required: [:stories],
      properties: %{
        stories: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              story_id: %Schema{type: :string, format: :uuid},
              reason: %Schema{type: :string}
            }
          }
        }
      }
    })
  end

  defmodule BulkResultResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BulkResultResponse",
      description: "Per-story results from a bulk operation",
      type: :object,
      properties: %{
        results: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              story_id: %Schema{type: :string, format: :uuid},
              status: %Schema{type: :string, enum: ["success", "error"]},
              error: %Schema{type: :string, nullable: true}
            }
          }
        }
      }
    })
  end
end
