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

  defmodule RateLimitError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RateLimitError",
      description: "Rate limit exceeded response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          required: [:status, :message],
          properties: %{
            status: %Schema{type: :integer, example: 429},
            message: %Schema{type: :string, example: "Rate limit exceeded"}
          }
        },
        retry_after: %Schema{
          type: :integer,
          description: "Seconds until rate limit resets",
          example: 45
        }
      },
      example: %{
        error: %{status: 429, message: "Rate limit exceeded"},
        retry_after: 45
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
      },
      example: %{page: 1, page_size: 20, total_count: 42, total_pages: 3}
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
      },
      example: %{
        id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        name: "My Org",
        slug: "my-org",
        email: "admin@example.com",
        settings: %{},
        status: "active",
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-01-15T10:00:00Z"
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
      },
      example: %{name: "my-key", role: "agent", expires_at: nil}
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
      },
      example: %{
        id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        name: "default",
        key_prefix: "lc_abc1",
        role: "user",
        last_used_at: "2026-03-25T14:30:00Z",
        expires_at: nil,
        revoked_at: nil,
        inserted_at: "2026-01-15T10:00:00Z"
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
      },
      example: %{
        id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        name: "My Project",
        slug: "my-project",
        repo_url: "https://github.com/org/repo",
        description: "An example project",
        tech_stack: "elixir,phoenix",
        status: "active",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-01-15T10:00:00Z"
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
      },
      example: %{
        id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        number: 1,
        title: "Foundation",
        description: "Core infrastructure and setup",
        phase: "p0",
        position: 1,
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-01-15T10:00:00Z"
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
      },
      example: %{
        id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        epic_id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        number: "US-2.1",
        title: "Implement user authentication",
        description: "Add login and session management",
        acceptance_criteria: [
          %{criterion: "Users can log in with email and password", met: false},
          %{criterion: "Invalid credentials return 401", met: false}
        ],
        estimated_hours: 4.0,
        agent_status: "pending",
        verified_status: "unverified",
        assigned_agent_id: nil,
        assigned_at: nil,
        reported_done_at: nil,
        verified_at: nil,
        rejected_at: nil,
        rejection_reason: nil,
        sort_key: "002.001",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-01-15T10:00:00Z"
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
      },
      example: %{
        story: %{
          id: "e5f6a7b8-c9d0-1234-efab-345678901234",
          number: "US-2.1",
          title: "Implement user authentication",
          agent_status: "contracted",
          verified_status: "unverified"
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

  # ---------- Verification / Rejection ----------

  defmodule VerifyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerifyRequest",
      description:
        "Orchestrator verifies a reported_done story. " <>
          "Requires review_type and summary as proof that an independent review was conducted.",
      type: :object,
      required: [:review_type, :summary],
      properties: %{
        result: %Schema{
          type: :string,
          enum: ["pass", "partial"],
          default: "pass",
          description: "Verification result: pass (full) or partial"
        },
        summary: %Schema{
          type: :string,
          description:
            "Required. Human-readable summary of the review findings. " <>
              "Must describe what was reviewed and what was found.",
          example: "Enhanced review: 2 rounds, 6 agents, 5 bugs fixed, 0 deferrals"
        },
        findings: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Structured findings from the review"
        },
        review_type: %Schema{
          type: :string,
          description:
            "Required. Type of independent review performed. " <>
              "Examples: enhanced, team, adversarial, single_agent",
          example: "enhanced"
        }
      },
      example: %{
        result: "pass",
        summary: "Enhanced review: 2 rounds, 6 agents, 5 bugs fixed, 0 deferrals",
        findings: %{},
        review_type: "enhanced"
      }
    })
  end

  defmodule RejectRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RejectRequest",
      description: "Orchestrator rejects a story with reason",
      type: :object,
      required: [:reason],
      properties: %{
        reason: %Schema{
          type: :string,
          description: "Rejection reason (required, cannot be blank)",
          example: "Missing LiveView tests"
        },
        findings: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Structured findings from the review"
        },
        review_type: %Schema{
          type: :string,
          description: "Type of review performed (e.g. enhanced_review, quick_check)",
          example: "enhanced_review"
        }
      },
      example: %{
        reason: "Missing LiveView tests",
        findings: %{missing_tests: ["empty input handling", "error boundary"]},
        review_type: "enhanced_review"
      }
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
      },
      example: %{
        artifact_type: "commit_diff",
        path: "abc123..def456",
        exists: true,
        details: %{files_changed: 5}
      }
    })
  end

  defmodule ArtifactReportResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ArtifactReportResponse",
      description: "Artifact report record",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        artifact_type: %Schema{type: :string},
        path: %Schema{type: :string},
        exists: %Schema{type: :boolean},
        details: %Schema{type: :object, additionalProperties: true},
        reported_by: %Schema{type: :string, enum: ["agent", "orchestrator"]},
        reporter_agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "f2a3b4c5-d6e7-8901-fabc-123456789012",
        story_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        artifact_type: "file",
        path: "lib/my_app/auth.ex",
        exists: true,
        details: %{line_count: 142},
        reported_by: "agent",
        reporter_agent_id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        inserted_at: "2026-03-25T14:30:00Z"
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
      },
      example: %{
        id: "d0e1f2a3-b4c5-6789-defa-890123456789",
        story_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        result: "pass",
        reason: "All acceptance criteria met",
        inserted_at: "2026-03-25T15:00:00Z"
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
      },
      example: %{name: "worker-1", agent_type: "implementer"}
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
      },
      example: %{
        id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        name: "worker-1",
        agent_type: "implementer",
        status: "active",
        last_seen_at: "2026-03-25T14:30:00Z",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-03-25T14:30:00Z"
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
        url: %Schema{type: :string, format: :uri, example: "https://example.com/webhook"},
        events: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: [
              "story.status_changed",
              "story.verified",
              "story.rejected",
              "story.auto_reset",
              "story.force_unclaimed",
              "epic.completed",
              "artifact.reported",
              "agent.registered",
              "project.imported",
              "webhook.test"
            ]
          },
          description: "Event types to subscribe to"
        },
        project_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      example: %{
        url: "https://example.com/webhook",
        events: ["story.verified", "story.rejected"],
        project_id: nil
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
      },
      example: %{
        id: "a7b8c9d0-e1f2-3456-abcd-567890123456",
        url: "https://example.com/webhook",
        events: ["story.verified", "story.rejected"],
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        active: true,
        consecutive_failures: 0,
        last_delivery_at: "2026-03-25T14:30:00Z",
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-03-25T14:30:00Z"
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
      },
      example: %{state_key: "main", state_data: %{phase: "epic_3"}, version: 0}
    })
  end

  defmodule OrchestratorStateResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OrchestratorStateResponse",
      description: "Orchestrator state checkpoint",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        project_id: %Schema{type: :string, format: :uuid},
        state_key: %Schema{type: :string},
        state_data: %Schema{type: :object, additionalProperties: true},
        version: %Schema{type: :integer},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "e1f2a3b4-c5d6-7890-efab-012345678901",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        state_key: "main",
        state_data: %{phase: "epic_3", current_epic: 3, stories_verified: 12},
        version: 5,
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-03-25T14:30:00Z"
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
      },
      example: %{
        id: "b8c9d0e1-f2a3-4567-bcde-678901234567",
        name: "loopctl:review",
        description: "Code review skill for orchestrator verification",
        current_version: 3,
        status: "active",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-03-20T09:15:00Z"
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
      },
      example: %{
        id: "c9d0e1f2-a3b4-5678-cdef-789012345678",
        skill_id: "b8c9d0e1-f2a3-4567-bcde-678901234567",
        version: 1,
        prompt_text:
          "You are reviewing code for correctness and adherence to acceptance criteria...",
        changelog: "Initial version",
        created_by: "orchestrator-main",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z"
      }
    })
  end

  # ---------- Import/Export ----------

  defmodule AcceptanceCriterion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AcceptanceCriterion",
      description:
        ~s(A single acceptance criterion. ) <>
          ~s(Accepts both `{"criterion": "..."}` and `{"id": "AC-1", "description": "..."}` formats. ) <>
          "When `description` is present it is mapped to `criterion` automatically.",
      type: :object,
      properties: %{
        criterion: %Schema{
          type: :string,
          description: "Acceptance criterion text (canonical key)"
        },
        description: %Schema{
          type: :string,
          description: "Acceptance criterion text (alias for criterion, normalized on import)"
        },
        id: %Schema{
          type: :string,
          description: "Optional identifier (e.g. \"AC-1\")",
          example: "AC-1"
        }
      },
      example: %{id: "AC-1", description: "POST /login returns JWT on valid credentials"}
    })
  end

  defmodule ImportStory do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImportStory",
      description: "Story within an import epic",
      type: :object,
      required: [:number, :title],
      properties: %{
        number: %Schema{
          type: :string,
          description: "Story number (e.g. \"1.1\")",
          example: "1.1"
        },
        title: %Schema{type: :string, example: "Implement login endpoint"},
        description: %Schema{type: :string, nullable: true},
        acceptance_criteria: %Schema{
          type: :array,
          items: AcceptanceCriterion,
          nullable: true,
          description: "List of acceptance criteria"
        },
        estimated_hours: %Schema{type: :number, nullable: true, example: 4.0},
        depends_on_stories: %Schema{
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          description: "Story numbers this story depends on"
        },
        initial_agent_status: %Schema{
          type: :string,
          enum: ["pending", "reported_done"],
          nullable: true,
          description:
            "Set initial agent status at import time. " <>
              "Use 'reported_done' for pre-existing work that has been completed."
        },
        initial_verified_status: %Schema{
          type: :string,
          enum: ["unverified", "verified"],
          nullable: true,
          description:
            "Set initial verified status at import time. " <>
              "Use 'verified' for pre-existing work that has already been verified. " <>
              "When set to 'verified', agent_status is also set to 'reported_done'."
        }
      },
      example: %{
        number: "1.1",
        title: "Implement login endpoint",
        acceptance_criteria: [%{criterion: "Returns JWT"}],
        estimated_hours: 4.0,
        initial_verified_status: "verified"
      }
    })
  end

  defmodule ImportEpic do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImportEpic",
      description: "Epic within an import payload",
      type: :object,
      required: [:number, :title],
      properties: %{
        number: %Schema{type: :integer, description: "Epic number", example: 1},
        title: %Schema{type: :string, example: "User Authentication"},
        description: %Schema{type: :string, nullable: true},
        phase: %Schema{type: :string, nullable: true},
        position: %Schema{type: :integer, nullable: true},
        stories: %Schema{
          type: :array,
          items: ImportStory,
          description: "Stories nested under this epic"
        }
      },
      example: %{
        number: 1,
        title: "User Authentication",
        stories: [%{number: "1.1", title: "Login endpoint"}]
      }
    })
  end

  defmodule ImportEpicDependency do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImportEpicDependency",
      description: "Epic-level dependency declaration",
      type: :object,
      required: [:epic, :depends_on],
      properties: %{
        epic: %Schema{type: :integer, description: "Epic number", example: 2},
        depends_on: %Schema{type: :integer, description: "Depends-on epic number", example: 1}
      },
      example: %{epic: 2, depends_on: 1}
    })
  end

  defmodule ImportStoryDependency do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImportStoryDependency",
      description: "Story-level dependency declaration",
      type: :object,
      required: [:story, :depends_on],
      properties: %{
        story: %Schema{type: :string, description: "Story number", example: "1.2"},
        depends_on: %Schema{type: :string, description: "Depends-on story number", example: "1.1"}
      },
      example: %{story: "1.2", depends_on: "1.1"}
    })
  end

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
          items: ImportEpic,
          description: "Array of epic objects with nested stories"
        },
        story_dependencies: %Schema{
          type: :array,
          items: ImportStoryDependency,
          description: "Optional cross-story dependencies",
          nullable: true
        },
        epic_dependencies: %Schema{
          type: :array,
          items: ImportEpicDependency,
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

  defmodule ExportMetadata do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportMetadata",
      description: "Metadata about the export",
      type: :object,
      properties: %{
        exported_at: %Schema{type: :string, format: :"date-time"},
        loopctl_version: %Schema{type: :string},
        project_id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid}
      },
      example: %{
        exported_at: "2026-03-25T14:30:00Z",
        loopctl_version: "0.1.0",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
      }
    })
  end

  defmodule ExportProject do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportProject",
      description: "Project metadata in an export",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        repo_url: %Schema{type: :string, nullable: true},
        tech_stack: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["active", "archived"]},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      example: %{
        name: "My Project",
        slug: "my-project",
        description: "An example project",
        repo_url: "https://github.com/org/repo",
        tech_stack: "elixir,phoenix",
        status: "active",
        metadata: %{}
      }
    })
  end

  defmodule ExportStory do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportStory",
      description: "Story within an export epic",
      type: :object,
      properties: %{
        number: %Schema{type: :string, example: "1.1"},
        title: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        acceptance_criteria: %Schema{
          type: :array,
          items: AcceptanceCriterion,
          nullable: true
        },
        estimated_hours: %Schema{type: :number, nullable: true},
        agent_status: %Schema{
          type: :string,
          enum: ["pending", "contracted", "assigned", "implementing", "reported_done"]
        },
        verified_status: %Schema{
          type: :string,
          enum: ["unverified", "verified", "rejected"]
        },
        assigned_agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        assigned_at: %Schema{type: :string, format: :"date-time", nullable: true},
        reported_done_at: %Schema{type: :string, format: :"date-time", nullable: true},
        verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        rejected_at: %Schema{type: :string, format: :"date-time", nullable: true},
        rejection_reason: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      example: %{
        number: "1.1",
        title: "Login endpoint",
        agent_status: "verified",
        verified_status: "verified",
        estimated_hours: 4.0
      }
    })
  end

  defmodule ExportEpic do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportEpic",
      description: "Epic within an export payload",
      type: :object,
      properties: %{
        number: %Schema{type: :integer},
        title: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        phase: %Schema{type: :string, nullable: true},
        position: %Schema{type: :integer},
        metadata: %Schema{type: :object, additionalProperties: true},
        stories: %Schema{type: :array, items: ExportStory}
      },
      example: %{
        number: 1,
        title: "User Authentication",
        description: "Auth infrastructure",
        phase: "p0",
        position: 1,
        metadata: %{},
        stories: [
          %{
            number: "1.1",
            title: "Implement login endpoint",
            agent_status: "reported_done",
            verified_status: "verified"
          }
        ]
      }
    })
  end

  defmodule ExportResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportResponse",
      description: "Complete project export with round-trip fidelity",
      type: :object,
      properties: %{
        export_metadata: ExportMetadata,
        project: ExportProject,
        epics: %Schema{type: :array, items: ExportEpic},
        story_dependencies: %Schema{
          type: :array,
          items: ImportStoryDependency,
          description: "Story-level dependencies using story numbers"
        },
        epic_dependencies: %Schema{
          type: :array,
          items: ImportEpicDependency,
          description: "Epic-level dependencies using epic numbers"
        }
      },
      example: %{
        export_metadata: %{
          exported_at: "2026-03-25T14:30:00Z",
          loopctl_version: "0.1.0",
          project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
          tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        },
        project: %{name: "My Project", slug: "my-project", status: "active"},
        epics: [
          %{
            number: 1,
            title: "Foundation",
            stories: [
              %{
                number: "1.1",
                title: "Setup",
                agent_status: "pending",
                verified_status: "unverified"
              }
            ]
          }
        ],
        story_dependencies: [],
        epic_dependencies: []
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
      },
      example: %{
        story_ids: [
          "e5f6a7b8-c9d0-1234-efab-345678901234",
          "f6a7b8c9-d0e1-2345-fabc-456789012345"
        ]
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
      },
      example: %{
        stories: [
          %{story_id: "e5f6a7b8-c9d0-1234-efab-345678901234", notes: "All ACs met"}
        ]
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
      },
      example: %{
        stories: [
          %{story_id: "e5f6a7b8-c9d0-1234-efab-345678901234", reason: "Missing LiveView tests"}
        ]
      }
    })
  end

  defmodule BulkStoryResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BulkStoryResult",
      description: "Result of a single story in a bulk operation",
      type: :object,
      required: [:story_id, :status],
      properties: %{
        story_id: %Schema{type: :string, format: :uuid, description: "The story ID"},
        status: %Schema{
          type: :string,
          enum: ["success", "error"],
          description: "Whether this story's operation succeeded"
        },
        error: %Schema{
          type: :string,
          nullable: true,
          description: "Error message if status is \"error\""
        }
      },
      example: %{
        story_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        status: "success",
        error: nil
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
      required: [:results],
      properties: %{
        results: %Schema{
          type: :array,
          items: BulkStoryResult,
          description: "One result per story in the request"
        }
      },
      example: %{
        results: [
          %{story_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890", status: "success", error: nil},
          %{
            story_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
            status: "error",
            error: "Story is not in reported_done status"
          }
        ]
      }
    })
  end

  # ---------- UI Tests ----------

  defmodule StartUiTestRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StartUiTestRequest",
      description: "Request body for starting a UI test run",
      type: :object,
      required: [:guide_reference],
      properties: %{
        guide_reference: %Schema{
          type: :string,
          description: "Path or URL to the user guide being followed",
          example: "docs/user_guides/checkout_flow.md"
        }
      },
      example: %{guide_reference: "docs/user_guides/checkout_flow.md"}
    })
  end

  defmodule UiTestFindingRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UiTestFindingRequest",
      description: "A structured finding recorded during a UI test run",
      type: :object,
      properties: %{
        step: %Schema{type: :string, description: "The UI step where the finding occurred"},
        severity: %Schema{
          type: :string,
          enum: ["critical", "high", "medium", "low"],
          description: "Finding severity level"
        },
        type: %Schema{
          type: :string,
          description: "Finding type (crash, wrong_behavior, ui_defect, etc.)"
        },
        description: %Schema{
          type: :string,
          description: "Human-readable description of the finding"
        },
        screenshot_path: %Schema{
          type: :string,
          nullable: true,
          description: "Optional path to a screenshot"
        },
        console_errors: %Schema{
          type: :string,
          nullable: true,
          description: "Optional console error output"
        }
      },
      example: %{
        step: "3. Submit checkout form",
        severity: "critical",
        type: "crash",
        description: "Page crashes with 500 error when submitting empty form",
        screenshot_path: "screenshots/checkout_crash.png",
        console_errors: "Uncaught TypeError: Cannot read properties of undefined"
      }
    })
  end

  defmodule CompleteUiTestRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CompleteUiTestRequest",
      description: "Request body for completing a UI test run",
      type: :object,
      required: [:status, :summary],
      properties: %{
        status: %Schema{
          type: :string,
          enum: ["passed", "failed"],
          description: "Final status of the test run"
        },
        summary: %Schema{
          type: :string,
          description: "Human-readable summary of the test run",
          example:
            "Tested 12 flows. Found 2 critical issues in checkout. Cart and auth flows passed."
        }
      },
      example: %{
        status: "failed",
        summary:
          "Tested 12 flows. Found 2 critical issues in checkout. Cart and auth flows passed."
      }
    })
  end

  defmodule UiTestRunResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UiTestRunResponse",
      description: "A UI test run resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        project_id: %Schema{type: :string, format: :uuid},
        started_by_agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        status: %Schema{
          type: :string,
          enum: ["in_progress", "passed", "failed", "cancelled"]
        },
        guide_reference: %Schema{type: :string},
        findings: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        },
        summary: %Schema{type: :string, nullable: true},
        screenshots_count: %Schema{type: :integer},
        findings_count: %Schema{type: :integer},
        critical_count: %Schema{type: :integer},
        high_count: %Schema{type: :integer},
        started_at: %Schema{type: :string, format: :"date-time"},
        completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        tenant_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        started_by_agent_id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        status: "in_progress",
        guide_reference: "docs/user_guides/checkout_flow.md",
        findings: [],
        summary: nil,
        screenshots_count: 0,
        findings_count: 0,
        critical_count: 0,
        high_count: 0,
        started_at: "2026-03-29T10:00:00Z",
        completed_at: nil,
        inserted_at: "2026-03-29T10:00:00Z",
        updated_at: "2026-03-29T10:00:00Z"
      }
    })
  end
end
