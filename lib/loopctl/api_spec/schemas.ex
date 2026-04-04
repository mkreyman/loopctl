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

  defmodule ReviewRecordResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReviewRecordResponse",
      description: "Review record proving an independent review was conducted",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        reviewer_agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        review_type: %Schema{type: :string},
        findings_count: %Schema{type: :integer},
        fixes_count: %Schema{type: :integer},
        summary: %Schema{type: :string, nullable: true},
        completed_at: %Schema{type: :string, format: :"date-time"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "f1a2b3c4-d5e6-7890-abcd-ef1234567890",
        tenant_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        story_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        reviewer_agent_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        review_type: "enhanced",
        findings_count: 5,
        fixes_count: 5,
        summary: "Enhanced review completed. 5 findings, all fixed.",
        completed_at: "2026-03-30T01:44:41Z",
        inserted_at: "2026-03-30T01:44:41Z",
        updated_at: "2026-03-30T01:44:41Z"
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
              "token.budget_warning",
              "token.budget_exceeded",
              "token.anomaly_detected",
              "webhook.test"
            ]
          },
          description: "Event types to subscribe to"
        },
        project_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      example: %{
        url: "https://example.com/webhook",
        events: ["story.verified", "story.rejected", "token.budget_warning"],
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
        events: ["story.verified", "story.rejected", "token.budget_warning"],
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

  # ---------- Token Efficiency ----------

  defmodule TokenUsageReport do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenUsageReport",
      description:
        "A token usage report for an agent story. Tracks input/output tokens, model name, " <>
          "and cost in millicents (1/1000 of a cent). Corrections use negative values.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        project_id: %Schema{type: :string, format: :uuid, nullable: true},
        input_tokens: %Schema{type: :integer, description: "Number of input tokens consumed"},
        output_tokens: %Schema{type: :integer, description: "Number of output tokens consumed"},
        total_tokens: %Schema{
          type: :integer,
          description: "DB-generated column: input_tokens + output_tokens"
        },
        model_name: %Schema{
          type: :string,
          description: "LLM model name",
          example: "claude-opus-4-5"
        },
        cost_millicents: %Schema{
          type: :integer,
          description: "Cost in millicents (1/1000 of a cent)"
        },
        cost_dollars: %Schema{
          type: :string,
          description: "Cost formatted as dollars (e.g. \"1.23\")",
          example: "1.23"
        },
        phase: %Schema{
          type: :string,
          enum: ["planning", "implementing", "reviewing", "other"],
          description: "Work phase when tokens were consumed"
        },
        session_id: %Schema{type: :string, nullable: true},
        skill_version_id: %Schema{type: :string, format: :uuid, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        deleted_at: %Schema{type: :string, format: :"date-time", nullable: true},
        corrects_report_id: %Schema{type: :string, format: :uuid, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        tenant_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        story_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        agent_id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        project_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        input_tokens: 125_000,
        output_tokens: 48_000,
        total_tokens: 173_000,
        model_name: "claude-opus-4-5",
        cost_millicents: 187_500,
        cost_dollars: "1.88",
        phase: "implementing",
        session_id: "sess_abc123",
        skill_version_id: nil,
        metadata: %{},
        deleted_at: nil,
        corrects_report_id: nil,
        inserted_at: "2026-03-25T14:30:00Z",
        updated_at: "2026-03-25T14:30:00Z"
      }
    })
  end

  defmodule TokenBudget do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenBudget",
      description:
        "A cost and token budget at project, epic, or story scope. " <>
          "Tracks alert thresholds and firing state for budget webhooks.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        scope_type: %Schema{
          type: :string,
          enum: ["project", "epic", "story"],
          description: "The scope level of the budget"
        },
        scope_id: %Schema{
          type: :string,
          format: :uuid,
          description: "UUID of the project, epic, or story"
        },
        budget_millicents: %Schema{
          type: :integer,
          description: "Total cost budget in millicents"
        },
        budget_dollars: %Schema{
          type: :string,
          description: "Budget formatted as dollars",
          example: "50.00"
        },
        budget_input_tokens: %Schema{
          type: :integer,
          nullable: true,
          description: "Optional input token budget"
        },
        budget_output_tokens: %Schema{
          type: :integer,
          nullable: true,
          description: "Optional output token budget"
        },
        alert_threshold_pct: %Schema{
          type: :integer,
          description: "Percentage at which to fire a warning webhook (1-100)"
        },
        current_spend_millicents: %Schema{
          type: :integer,
          description: "Current spend in millicents (computed at query time)"
        },
        current_spend_dollars: %Schema{
          type: :string,
          description: "Current spend formatted as dollars"
        },
        remaining_millicents: %Schema{
          type: :integer,
          description: "Remaining budget in millicents (budget - spend, floored at 0)"
        },
        remaining_dollars: %Schema{type: :string, description: "Remaining budget as dollars"},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        tenant_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        scope_type: "project",
        scope_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        budget_millicents: 5_000_000,
        budget_dollars: "50.00",
        budget_input_tokens: nil,
        budget_output_tokens: nil,
        alert_threshold_pct: 80,
        current_spend_millicents: 3_750_000,
        current_spend_dollars: "37.50",
        remaining_millicents: 1_250_000,
        remaining_dollars: "12.50",
        metadata: %{},
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-03-25T14:30:00Z"
      }
    })
  end

  defmodule CostSummary do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CostSummary",
      description:
        "Aggregated cost summary for a scope (story, epic, project) over a time period. " <>
          "Used for analytics and budget utilization calculations.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        scope_type: %Schema{
          type: :string,
          enum: ["story", "epic", "project"],
          description: "The aggregation scope"
        },
        scope_id: %Schema{type: :string, format: :uuid},
        period_start: %Schema{type: :string, format: :date, description: "Period start date"},
        period_end: %Schema{type: :string, format: :date, description: "Period end date"},
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        report_count: %Schema{type: :integer},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        tenant_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        scope_type: "project",
        scope_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        period_start: "2026-03-01",
        period_end: "2026-03-31",
        total_input_tokens: 2_500_000,
        total_output_tokens: 980_000,
        total_tokens: 3_480_000,
        total_cost_millicents: 3_720_000,
        report_count: 142,
        inserted_at: "2026-04-01T00:00:00Z",
        updated_at: "2026-04-01T00:00:00Z"
      }
    })
  end

  defmodule CostAnomaly do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CostAnomaly",
      description:
        "A detected cost anomaly for a story. Generated by the daily rollup worker. " <>
          "Types: high_cost (>3x epic avg), suspiciously_low (<0.1x), " <>
          "budget_exceeded (over configured budget).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        anomaly_type: %Schema{
          type: :string,
          enum: ["high_cost", "suspiciously_low", "budget_exceeded"],
          description: "Type of cost anomaly detected"
        },
        story_cost_millicents: %Schema{
          type: :integer,
          description: "The story's actual total cost in millicents"
        },
        reference_avg_millicents: %Schema{
          type: :integer,
          description: "The epic average cost used for comparison"
        },
        deviation_factor: %Schema{
          type: :number,
          description: "How many times the story cost deviates from the reference average"
        },
        resolved: %Schema{
          type: :boolean,
          description: "Whether the anomaly has been acknowledged and resolved"
        },
        archived: %Schema{
          type: :boolean,
          description: "Whether the anomaly is archived (excluded from default list)"
        },
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      example: %{
        id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        tenant_id: "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        story_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        anomaly_type: "high_cost",
        story_cost_millicents: 450_000,
        reference_avg_millicents: 125_000,
        deviation_factor: 3.6,
        resolved: false,
        archived: false,
        metadata: %{},
        inserted_at: "2026-03-26T01:00:00Z",
        updated_at: "2026-03-26T01:00:00Z"
      }
    })
  end

  defmodule TokenAnalyticsAgent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenAnalyticsAgent",
      description: "Per-agent cost and token metrics with efficiency ranking.",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        agent_name: %Schema{type: :string},
        total_stories_reported: %Schema{type: :integer},
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        avg_cost_per_story_millicents: %Schema{type: :integer},
        primary_model: %Schema{
          type: :string,
          nullable: true,
          description: "Most frequently used model",
          example: "claude-sonnet-4-5"
        },
        efficiency_rank: %Schema{
          type: :integer,
          description: "Rank by avg cost per story (1 = most efficient)"
        }
      },
      example: %{
        agent_id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        agent_name: "worker-3",
        total_stories_reported: 18,
        total_input_tokens: 2_250_000,
        total_output_tokens: 864_000,
        total_cost_millicents: 2_943_000,
        avg_cost_per_story_millicents: 163_500,
        primary_model: "claude-sonnet-4-5",
        efficiency_rank: 1
      }
    })
  end

  defmodule TokenAnalyticsEpic do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenAnalyticsEpic",
      description: "Per-epic cost breakdown including budget utilization and model breakdown.",
      type: :object,
      properties: %{
        epic_id: %Schema{type: :string, format: :uuid},
        epic_title: %Schema{type: :string},
        epic_number: %Schema{type: :integer},
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        story_count: %Schema{type: :integer},
        avg_cost_per_story_millicents: %Schema{type: :integer},
        budget_millicents: %Schema{
          type: :integer,
          nullable: true,
          description: "Configured budget for this epic (nil if no budget)"
        },
        budget_utilization_pct: %Schema{
          type: :number,
          nullable: true,
          description: "Percentage of budget consumed (nil if no budget)"
        }
      },
      example: %{
        epic_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        epic_title: "Token Efficiency",
        epic_number: 21,
        total_input_tokens: 1_875_000,
        total_output_tokens: 720_000,
        total_cost_millicents: 2_475_000,
        story_count: 11,
        avg_cost_per_story_millicents: 225_000,
        budget_millicents: 3_000_000,
        budget_utilization_pct: 82.5
      }
    })
  end

  defmodule TokenAnalyticsProject do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenAnalyticsProject",
      description:
        "Comprehensive cost overview for a single project including phase and model breakdown.",
      type: :object,
      properties: %{
        project_id: %Schema{type: :string, format: :uuid},
        project_name: %Schema{type: :string},
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        story_count: %Schema{type: :integer},
        epic_count: %Schema{type: :integer},
        avg_cost_per_story_millicents: %Schema{type: :integer},
        phase_breakdown: %Schema{
          type: :object,
          description: "Cost breakdown by phase (planning, implementing, reviewing, other)",
          additionalProperties: true
        },
        model_breakdown: %Schema{
          type: :object,
          description: "Cost breakdown by model name",
          additionalProperties: true
        },
        budget_millicents: %Schema{type: :integer, nullable: true},
        budget_utilization_pct: %Schema{type: :number, nullable: true}
      },
      example: %{
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        project_name: "loopctl",
        total_input_tokens: 12_500_000,
        total_output_tokens: 4_800_000,
        total_cost_millicents: 16_650_000,
        story_count: 60,
        epic_count: 15,
        avg_cost_per_story_millicents: 277_500,
        phase_breakdown: %{
          implementing: 9_800_000,
          reviewing: 4_200_000,
          planning: 1_900_000,
          other: 750_000
        },
        model_breakdown: %{
          "claude-opus-4-5": 12_300_000,
          "claude-sonnet-4-5": 3_800_000,
          "claude-haiku-3-5": 550_000
        },
        budget_millicents: 20_000_000,
        budget_utilization_pct: 83.25
      }
    })
  end

  defmodule TokenAnalyticsModel do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenAnalyticsModel",
      description: "Per-model token usage, cost, and verification correlation metrics.",
      type: :object,
      properties: %{
        model_name: %Schema{type: :string, example: "claude-opus-4-5"},
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        story_count: %Schema{
          type: :integer,
          description: "Number of stories that used this model"
        },
        verified_count: %Schema{
          type: :integer,
          description: "Number of those stories that were verified"
        },
        verification_rate: %Schema{
          type: :number,
          description: "Fraction of stories verified (0.0 to 1.0)"
        },
        avg_cost_per_story_millicents: %Schema{type: :integer}
      },
      example: %{
        model_name: "claude-opus-4-5",
        total_input_tokens: 8_750_000,
        total_output_tokens: 3_360_000,
        total_cost_millicents: 11_880_000,
        story_count: 42,
        verified_count: 39,
        verification_rate: 0.929,
        avg_cost_per_story_millicents: 282_857
      }
    })
  end

  defmodule TokenAnalyticsTrend do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenAnalyticsTrend",
      description: "A single data point in a daily or weekly cost trend series.",
      type: :object,
      properties: %{
        period: %Schema{
          type: :string,
          description: "Period label: ISO date for daily, ISO week (YYYY-Www) for weekly",
          example: "2026-03-25"
        },
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        report_count: %Schema{type: :integer},
        story_count: %Schema{
          type: :integer,
          description: "Number of distinct stories with reports in this period"
        }
      },
      example: %{
        period: "2026-03-25",
        total_input_tokens: 487_000,
        total_output_tokens: 189_000,
        total_cost_millicents: 648_000,
        report_count: 12,
        story_count: 8
      }
    })
  end

  defmodule ModelMixEntry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ModelMixEntry",
      description:
        "A (model_name, phase) correlation matrix entry with token totals, " <>
          "cost, story count, and verification outcomes.",
      type: :object,
      properties: %{
        model_name: %Schema{type: :string, example: "claude-opus-4-5"},
        phase: %Schema{
          type: :string,
          enum: ["planning", "implementing", "reviewing", "other"]
        },
        total_input_tokens: %Schema{type: :integer},
        total_output_tokens: %Schema{type: :integer},
        total_cost_millicents: %Schema{type: :integer},
        story_count: %Schema{type: :integer},
        verified_count: %Schema{type: :integer},
        verification_rate: %Schema{type: :number}
      },
      example: %{
        model_name: "claude-opus-4-5",
        phase: "implementing",
        total_input_tokens: 6_250_000,
        total_output_tokens: 2_400_000,
        total_cost_millicents: 8_550_000,
        story_count: 30,
        verified_count: 28,
        verification_rate: 0.933
      }
    })
  end

  defmodule WebhookTokenBudgetWarningPayload do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookTokenBudgetWarningPayload",
      description:
        "Payload for token.budget_warning webhook event. " <>
          "Fired once when spend crosses the alert_threshold_pct. " <>
          "Resets if budget_millicents or alert_threshold_pct is updated.",
      type: :object,
      properties: %{
        budget_id: %Schema{type: :string, format: :uuid},
        scope_type: %Schema{type: :string, enum: ["project", "epic", "story"]},
        scope_id: %Schema{type: :string, format: :uuid},
        budget_millicents: %Schema{type: :integer},
        current_spend_millicents: %Schema{type: :integer},
        utilization_pct: %Schema{type: :number},
        alert_threshold_pct: %Schema{type: :integer},
        triggering_report_id: %Schema{type: :string, format: :uuid}
      },
      example: %{
        budget_id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        scope_type: "project",
        scope_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        budget_millicents: 5_000_000,
        current_spend_millicents: 4_050_000,
        utilization_pct: 81.0,
        alert_threshold_pct: 80,
        triggering_report_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
      }
    })
  end

  defmodule WebhookTokenBudgetExceededPayload do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookTokenBudgetExceededPayload",
      description:
        "Payload for token.budget_exceeded webhook event. " <>
          "Fired once when spend reaches or exceeds 100% of the budget. " <>
          "Includes overage_millicents showing how far over budget.",
      type: :object,
      properties: %{
        budget_id: %Schema{type: :string, format: :uuid},
        scope_type: %Schema{type: :string, enum: ["project", "epic", "story"]},
        scope_id: %Schema{type: :string, format: :uuid},
        budget_millicents: %Schema{type: :integer},
        current_spend_millicents: %Schema{type: :integer},
        utilization_pct: %Schema{type: :number},
        alert_threshold_pct: %Schema{type: :integer},
        triggering_report_id: %Schema{type: :string, format: :uuid},
        overage_millicents: %Schema{
          type: :integer,
          description: "Amount by which spend exceeded the budget"
        }
      },
      example: %{
        budget_id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        scope_type: "epic",
        scope_id: "e5f6a7b8-c9d0-1234-efab-345678901234",
        budget_millicents: 3_000_000,
        current_spend_millicents: 3_187_500,
        utilization_pct: 106.25,
        alert_threshold_pct: 80,
        triggering_report_id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        overage_millicents: 187_500
      }
    })
  end

  defmodule WebhookTokenAnomalyDetectedPayload do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookTokenAnomalyDetectedPayload",
      description:
        "Payload for token.anomaly_detected webhook event. " <>
          "Fired by the daily rollup worker when a story's cost deviates significantly " <>
          "from the epic average. Includes story title and agent name for context.",
      type: :object,
      properties: %{
        anomaly_id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        story_title: %Schema{type: :string, nullable: true},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        agent_name: %Schema{type: :string, nullable: true},
        anomaly_type: %Schema{
          type: :string,
          enum: ["high_cost", "suspiciously_low", "budget_exceeded"]
        },
        story_cost_millicents: %Schema{type: :integer},
        reference_avg_millicents: %Schema{type: :integer},
        deviation_factor: %Schema{type: :string, description: "Decimal string (e.g. \"3.60\")"}
      },
      example: %{
        anomaly_id: "d4e5f6a7-b8c9-0123-defa-234567890123",
        story_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        story_title: "Implement token analytics endpoints",
        agent_id: "f6a7b8c9-d0e1-2345-fabc-456789012345",
        agent_name: "worker-3",
        anomaly_type: "high_cost",
        story_cost_millicents: 450_000,
        reference_avg_millicents: 125_000,
        deviation_factor: "3.60"
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
