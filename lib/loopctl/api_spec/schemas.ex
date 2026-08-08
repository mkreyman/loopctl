defmodule Loopctl.ApiSpec.Schemas do
  alias Loopctl.ApiSpec.Messages

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
            },
            code: %Schema{
              type: :string,
              description:
                "Stable machine-readable error code, when the endpoint emits one " <>
                  "(e.g. `custody_tier_required` for the trust-tier gate, " <>
                  "`insufficient_role` for the orthogonal role gate). Branch on this, " <>
                  "never on `message`.",
              example: "custody_tier_required"
            },
            capabilities: %Schema{
              type: :object,
              additionalProperties: true,
              description:
                "#505 — present on `custody_tier_required` and `insufficient_role` (403): " <>
                  "the same trust-tier capability map `GET /api/v1/tenants/me` advertises, " <>
                  "minus the static per-surface `descriptions`, so a caller can recover " <>
                  "without a second round trip. It covers the TIER gate only — `scope` and " <>
                  "`note` say so in the payload. See `TenantResponse.capabilities`.",
              nullable: true
            },
            required_role: %Schema{
              type: :string,
              nullable: true,
              description: "On `insufficient_role`: the minimum role the endpoint requires.",
              example: "orchestrator"
            },
            required_roles: %Schema{
              type: :array,
              nullable: true,
              items: %Schema{type: :string},
              description:
                "On `insufficient_role` for an exact-role gate: the roles accepted, with " <>
                  "NO hierarchy — a higher role is rejected too.",
              example: ["agent", "orchestrator"]
            },
            remediation: %Schema{
              type: :object,
              additionalProperties: true,
              description:
                "#505 — how to get unblocked: `learn_more`, `enrollment_upgrade`, and " <>
                  "`agent_native_alternative` (the agent-role endpoint covering the " <>
                  "adjacent non-custody need) when the gated mount names one. THIS block " <>
                  "wins over the nested `capabilities.remediation`: it is that same block " <>
                  "plus the endpoint-specific alternative.",
              nullable: true,
              properties: %{
                learn_more: %Schema{type: :string},
                enrollment_upgrade: %Schema{
                  type: :object,
                  description:
                    "How to upgrade THIS tenant in place (enroll a WebAuthn authenticator " <>
                      "against it) — NOT a second signup, which would strand the knowledge " <>
                      "this tenant owns.",
                  properties: %{
                    summary: %Schema{type: :string},
                    tools: %Schema{type: :array, items: %Schema{type: :string}},
                    endpoints: %Schema{type: :array, items: %Schema{type: :string}},
                    requires_human: %Schema{type: :boolean},
                    requires_role: %Schema{type: :string},
                    # #541 — the endpoints above need a browser
                    # (navigator.credentials.create), so the machine-actionable
                    # fields alone are a dead end for the agent reading this.
                    # RELATIVE: the page is per-deployment, bound to that
                    # instance's WEBAUTHN_RP_ID, unlike `docs`.
                    enrollment_page: %Schema{
                      type: :string,
                      example: "/enroll",
                      description:
                        "Relative path to THIS deployment's browser enrollment page — the " <>
                          "only way to run the WebAuthn ceremony the endpoints above require."
                    },
                    docs: %Schema{type: :string}
                  }
                },
                agent_native_alternative: %Schema{
                  type: :object,
                  nullable: true,
                  properties: %{
                    tool: %Schema{type: :string, example: "create_kb_scope"},
                    endpoint: %Schema{type: :string, example: "POST /api/v1/kb-scopes"},
                    description: %Schema{type: :string}
                  }
                }
              }
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
      description:
        "Rate limit exceeded. Default limits: 300 requests/minute per API key and 3x that " <>
          "per tenant (superadmin keys are exempt; per-tenant overrides via the " <>
          "`rate_limit_requests_per_minute` setting). Back off using the response headers: " <>
          "`Retry-After` (seconds until the window resets, always >= 1), plus `X-RateLimit-Limit`, " <>
          "`X-RateLimit-Remaining`, and `X-RateLimit-Reset` (Unix epoch seconds), which are set " <>
          "on every response.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          required: [:status, :message],
          properties: %{
            status: %Schema{type: :integer, example: 429},
            message: %Schema{type: :string, example: "Rate limit exceeded"}
          }
        }
      },
      example: %{
        error: %{status: 429, message: "Rate limit exceeded"}
      }
    })
  end

  defmodule PromotionBudgetError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromotionBudgetError",
      description:
        "Promotion budget exceeded (HTTP 429). Distinct from the generic request " <>
          "RateLimitError: this is the tenant's PER-HOUR memory-promotion (compile) " <>
          "budget — a semantic limit that caps how many session→long-term promotions " <>
          "may run per hour so a spamming agent cannot exhaust the tenant's BYO LLM " <>
          "key. The session was NOT enqueued and no LLM call was made. Unlike the " <>
          "request limiter, this response carries a machine-readable `error.code` of " <>
          "`promotion_budget_exceeded` and does NOT set `Retry-After` or " <>
          "`X-RateLimit-*` headers (the budget refills on a rolling hourly window, " <>
          "not a fixed per-request window) — clients should back off and retry later " <>
          "rather than read a reset header.",
      type: :object,
      required: [:error],
      properties: %{
        error: %Schema{
          type: :object,
          required: [:status, :code, :message],
          properties: %{
            status: %Schema{type: :integer, example: 429},
            code: %Schema{
              type: :string,
              enum: ["promotion_budget_exceeded"],
              example: "promotion_budget_exceeded"
            },
            message: %Schema{
              type: :string,
              example:
                "The tenant's per-hour memory-promotion budget has been reached. " <>
                  "The session was not enqueued and no LLM call was made; retry later."
            }
          }
        }
      },
      example: %{
        error: %{
          status: 429,
          code: "promotion_budget_exceeded",
          message:
            "The tenant's per-hour memory-promotion budget has been reached. " <>
              "The session was not enqueued and no LLM call was made; retry later."
        }
      }
    })
  end

  defmodule IngestionBacklogError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "IngestionBacklogError",
      description:
        "Ingest backpressure (HTTP 429). Distinct from the generic request " <>
          "RateLimitError: this is triggered BEFORE any item is enqueued, for one of TWO " <>
          "causes — the calling tenant's in-flight `:ingestion` backlog (non-terminal Oban " <>
          "jobs) is at/over the `OBAN_INGEST_BACKLOG_MAX` threshold, OR that backlog could " <>
          "not be MEASURED (transient count-path fault) and the bounded fail-open allowance " <>
          "for that fault is spent. On the second the backlog was never counted and may be " <>
          "zero, so waiting for it to drain is not necessarily the remedy — it is a " <>
          "server-side condition. The rejection is all-or-nothing — NO jobs from the " <>
          "request are enqueued (no partial pile-up). The check is tenant-scoped: only the " <>
          "caller's own backlog counts. Unlike the Hammer request-rate limiter, this " <>
          "response carries a machine-readable `error.code` of `ingestion_backlog_exceeded`, " <>
          "so dashboards/clients can tell it apart from the request-rate 429. It DOES set " <>
          "`Retry-After` (seconds) — honour it either way.",
      type: :object,
      required: [:error],
      properties: %{
        error: %Schema{
          type: :object,
          required: [:status, :code, :message],
          properties: %{
            status: %Schema{type: :integer, example: 429},
            code: %Schema{
              type: :string,
              enum: ["ingestion_backlog_exceeded"],
              example: "ingestion_backlog_exceeded"
            },
            message: %Schema{
              type: :string,
              example: Messages.ingestion_backlog_exceeded(5)
            },
            retry_after_seconds: %Schema{type: :integer, example: 5}
          }
        }
      },
      example: %{
        error: %{
          status: 429,
          code: "ingestion_backlog_exceeded",
          message: Messages.ingestion_backlog_exceeded(5),
          retry_after_seconds: 5
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
        status: %Schema{
          type: :string,
          enum: ["active", "suspended", "deactivated", "pending_enrollment"]
        },
        trust_tier: %Schema{
          type: :string,
          enum: ["human_anchored", "agent_rooted"],
          description:
            "US-26.7.1 — human_anchored (WebAuthn signup) unlocks the work-breakdown " <>
              "/ chain-of-custody surface; agent_rooted (self-signup) is KB-tier only."
        },
        capabilities: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "#505 — which surfaces this tenant's `trust_tier` includes, so a caller can " <>
              "discover the boundary BEFORE a write instead of probing for a 403. " <>
              "`surfaces` maps each surface to either `allowed` or `requires_human_anchor`; " <>
              "`allowed`/`blocked` are the same split as lists; `descriptions` explains " <>
              "each surface; `remediation` (present only when `blocked` is non-empty) " <>
              "carries the in-place enrollment-upgrade path. `scope: trust_tier_only` and " <>
              "`applies_to: mutating_actions` bound the claim: the ROLE gate applies " <>
              "independently (an `allowed` surface can still 403 `insufficient_role`), and " <>
              "READS stay open on every surface, including blocked ones. The same map " <>
              "(minus `descriptions`) is embedded in the `custody_tier_required` and " <>
              "`insufficient_role` 403 bodies."
        },
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
        trust_tier: "human_anchored",
        capabilities: %{
          trust_tier: "human_anchored",
          surfaces: %{knowledge_base: "allowed", work_breakdown: "allowed"},
          allowed: ["knowledge_base", "work_breakdown"],
          blocked: []
        },
        inserted_at: "2026-01-15T10:00:00Z",
        updated_at: "2026-01-15T10:00:00Z"
      }
    })
  end

  defmodule TenantUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TenantUpdateRequest",
      description:
        "Request body for `PATCH /api/v1/tenants/me` (and the superadmin " <>
          "`PATCH /api/v1/admin/tenants/:id`). NOTE: `slug` is intentionally " <>
          "absent — it is immutable after creation because it keys the tenant's " <>
          "audit-key secret name (security: rls-02, advisory GHSA-v62j-7vgr-rfqp). " <>
          "Sending `slug` has no effect.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Tenant display name"},
        email: %Schema{type: :string, format: :email, description: "Contact email"},
        settings: %Schema{type: :object, additionalProperties: true},
        default_story_budget_millicents: %Schema{
          type: :integer,
          nullable: true,
          description: "Tenant-wide default story budget (millicents); null to unset"
        },
        token_data_retention_days: %Schema{
          type: :integer,
          nullable: true,
          description: "Token-usage retention in days (>= 30); null disables archival"
        }
      },
      example: %{
        name: "My Org",
        email: "admin@example.com",
        settings: %{},
        token_data_retention_days: 90
      }
    })
  end

  defmodule SelfSignupRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SelfSignupRequest",
      description:
        "Request body for `POST /api/v1/signup` (US-26.7.1). Creates an " <>
          "agent-rooted (KB-tier) tenant with no WebAuthn ceremony. Only " <>
          "`name`, `slug`, and `email` are accepted — any other field " <>
          "(`trust_tier`, `role`, `tenant_id`, `agent_id`, ...) is ignored.",
      type: :object,
      required: [:name, :slug, :email],
      properties: %{
        name: %Schema{type: :string, description: "Tenant display name", maxLength: 120},
        slug: %Schema{type: :string, description: "URL-safe unique slug", maxLength: 64},
        email: %Schema{type: :string, format: :email, description: "Contact email"}
      },
      example: %{
        name: "Stranger Agent Co",
        slug: "stranger-agent-co",
        email: "agent@stranger.example"
      }
    })
  end

  defmodule SelfSignupResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SelfSignupResponse",
      description:
        "Response for `POST /api/v1/signup`. `raw_key` (role `user`, tenant-bound) " <>
          "is returned exactly once — it is never persisted in plaintext and cannot " <>
          "be retrieved again.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tenant: TenantResponse,
            raw_key: %Schema{type: :string, description: "One-time root API key (role: user)"},
            next_action: %Schema{type: :object, additionalProperties: true}
          }
        }
      },
      example: %{
        data: %{
          tenant: %{
            id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            name: "Stranger Agent Co",
            slug: "stranger-agent-co",
            email: "agent@stranger.example",
            trust_tier: "agent_rooted",
            status: "active"
          },
          raw_key: "lc_...",
          next_action: %{
            message: "Configure your BYO LLM keys, then start ingesting/searching the wiki.",
            configure_llm: "PATCH /api/v1/tenants/me/llm-config"
          }
        }
      }
    })
  end

  # ---------- WebAuthn signup (US-26.0.1) ----------

  defmodule WebAuthnChallenge do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebAuthnChallenge",
      description:
        "Registration challenge served by the signup LiveView and fed into " <>
          "`navigator.credentials.create()`. All binary fields are base64url encoded.",
      type: :object,
      required: [:challenge, :rp_id],
      properties: %{
        challenge: %Schema{
          type: :string,
          description: "Base64url-encoded challenge bytes (32 bytes by default)"
        },
        rp_id: %Schema{
          type: :string,
          description:
            "Relying party id, deployment-configured (`WEBAUTHN_RP_ID`) — the hosted " <>
              "instance serves `loopctl.com`, a self-hosted one its own domain, `localhost` " <>
              "in dev. It must be a registrable domain suffix of the page's origin or the " <>
              "browser refuses the ceremony."
        },
        rp_name: %Schema{type: :string, example: "loopctl"},
        user_verification: %Schema{
          type: :string,
          enum: ["discouraged", "preferred", "required"],
          example: "preferred"
        }
      }
    })
  end

  defmodule WebAuthnAttestation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebAuthnAttestation",
      description:
        "Raw attestation payload posted back from the browser after calling " <>
          "`navigator.credentials.create()`. All binary fields are base64url encoded.",
      type: :object,
      required: [:credential_id, :attestation_object, :client_data_json],
      properties: %{
        credential_id: %Schema{
          type: :string,
          description: "Base64url-encoded FIDO2 credential id"
        },
        attestation_object: %Schema{
          type: :string,
          description: "Base64url-encoded CBOR attestation object"
        },
        client_data_json: %Schema{
          type: :string,
          description: "Base64url-encoded JSON from the browser WebAuthn API"
        },
        friendly_name: %Schema{
          type: :string,
          description: "Operator-supplied label for this authenticator",
          example: "Primary YubiKey"
        }
      }
    })
  end

  defmodule TenantSignupRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TenantSignupRequest",
      description:
        "Request body submitted by the `/signup` LiveView after the operator " <>
          "has enrolled at least one FIDO2 authenticator via WebAuthn.",
      type: :object,
      required: [:name, :slug, :email, :authenticators],
      properties: %{
        name: %Schema{type: :string, description: "Tenant display name", example: "My Org"},
        slug: %Schema{
          type: :string,
          description: "Unique slug (lowercase, hyphens, 2-64 chars)",
          example: "my-org"
        },
        email: %Schema{
          type: :string,
          format: :email,
          description: "Contact email",
          example: "admin@example.com"
        },
        authenticators: %Schema{
          type: :array,
          description: "1..5 WebAuthn attestations, each verified server-side",
          items: WebAuthnAttestation,
          minItems: 1,
          maxItems: 5
        }
      },
      example: %{
        name: "My Org",
        slug: "my-org",
        email: "admin@example.com",
        authenticators: [
          %{
            credential_id: "abc123...",
            attestation_object: "xyz789...",
            client_data_json: "eyJ0...",
            friendly_name: "Primary YubiKey"
          }
        ]
      }
    })
  end

  defmodule ReauthChallengeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReauthChallengeResponse",
      description:
        "Step 1 of the audit-key rotation reauth ceremony (crypto-01). The " <>
          "server-minted, single-use `challenge_id` must be echoed back in the " <>
          "assertion step. All binary fields are base64url encoded.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:challenge_id, :challenge, :allowed_credentials],
          properties: %{
            challenge_id: %Schema{
              type: :string,
              format: :uuid,
              description: "Opaque single-use handle for the stored challenge"
            },
            challenge: %Schema{
              type: :string,
              description:
                "Base64url-encoded challenge bytes to feed into navigator.credentials.get()"
            },
            allowed_credentials: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Base64url credential ids the client may assert with"
            },
            rp_id: %Schema{type: :string, description: "Relying party id"},
            expires_at: %Schema{type: :string, format: :"date-time"}
          }
        }
      }
    })
  end

  defmodule WebAuthnAssertion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebAuthnAssertion",
      description:
        "Assertion produced by `navigator.credentials.get()`, posted back to " <>
          "verify a reauth challenge. All binary fields are base64url encoded and " <>
          "are SEPARATE values (never one blob reused for all fields).",
      type: :object,
      required: [
        :challenge_id,
        :credential_id,
        :authenticator_data,
        :signature,
        :client_data_json
      ],
      properties: %{
        challenge_id: %Schema{
          type: :string,
          format: :uuid,
          description: "The `challenge_id` returned by the challenge step"
        },
        credential_id: %Schema{type: :string, description: "Base64url asserting credential id"},
        authenticator_data: %Schema{type: :string, description: "Base64url authenticator data"},
        signature: %Schema{type: :string, description: "Base64url assertion signature"},
        client_data_json: %Schema{type: :string, description: "Base64url raw client data JSON"}
      }
    })
  end

  defmodule RotateAuditKeyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RotateAuditKeyRequest",
      description:
        "Step 2 of the reauth ceremony. Carries the WebAuthn assertion that is " <>
          "verified against the STORED challenge from step 1 before rotation.",
      type: :object,
      required: [:webauthn_assertion],
      properties: %{
        webauthn_assertion: WebAuthnAssertion
      }
    })
  end

  defmodule ReauthAssertionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReauthAssertionRequest",
      description:
        "Step 2 of the challenge-bound WebAuthn reauthentication ceremony, shared by " <>
          "every custody-critical operation that gates on a fresh assertion (e.g. " <>
          "break-glass clear-halt). Carries the WebAuthn assertion that is verified " <>
          "against the STORED challenge from step 1 before the operation proceeds.",
      type: :object,
      required: [:webauthn_assertion],
      properties: %{
        webauthn_assertion: WebAuthnAssertion
      }
    })
  end

  defmodule Capability do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Capability",
      description:
        "An L1 capability token. `cap_id` is the value presented as the `capability` " <>
          "field on the custody call it authorizes. A token is single-use, bound to one " <>
          "story, one type, and one dispatch lineage, and expires.",
      type: :object,
      properties: %{
        cap_id: %Schema{type: :string, format: :uuid},
        typ: %Schema{
          type: :string,
          description: "Only `start_cap` is minted today (#621)."
        },
        story_id: %Schema{type: :string, format: :uuid},
        issued_to_lineage: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          description: "Dispatch lineage the token is bound to; must match exactly at use."
        },
        issued_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time"},
        nonce: %Schema{type: :string, description: "Base64url"},
        signature: %Schema{type: :string, description: "Base64url ed25519 signature"}
      }
    })
  end

  defmodule CapabilityListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CapabilityListResponse",
      description:
        "Live capability tokens already issued to the CALLER for a story. Scoped by the " <>
          "caller's dispatch lineage, or — for an agent key not minted by a dispatch — by " <>
          "the story's assigned agent. Empty when neither matches.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{type: :array, items: Capability}
      }
    })
  end

  defmodule AuditKeyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditKeyResponse",
      description: "Result of an audit-key rotation or bootstrap.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tenant_id: %Schema{type: :string, format: :uuid},
            audit_signing_public_key: %Schema{
              type: :string,
              description: "Base64-encoded ed25519 public key"
            },
            rotated_at: %Schema{type: :string, format: :"date-time", nullable: true},
            message: %Schema{type: :string}
          }
        }
      }
    })
  end

  defmodule AuthenticatorChallengeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthenticatorChallengeResponse",
      description:
        "Step 1 of the opt-in WebAuthn enrollment ceremony (US-26.7.2). Returns the " <>
          "publicKey creation options a browser WebAuthn client needs to call " <>
          "navigator.credentials.create(). If the tenant is already human_anchored, " <>
          "also includes a fresh-assertion (reauth) challenge for an EXISTING " <>
          "authenticator (`reauth_required: true`) — a subsequent enrollment must " <>
          "prove possession of an already-enrolled device before adding a backup.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:challenge_id, :challenge, :expires_at, :rp, :user, :pub_key_cred_params],
          properties: %{
            challenge_id: %Schema{
              type: :string,
              format: :uuid,
              description: "Opaque single-use handle for the stored registration challenge"
            },
            challenge: %Schema{
              type: :string,
              description:
                "Base64url-encoded challenge bytes to feed into navigator.credentials.create()"
            },
            expires_at: %Schema{type: :string, format: :"date-time"},
            rp: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, description: "Relying party id"},
                name: %Schema{type: :string, description: "Relying party display name"}
              }
            },
            user: %Schema{
              type: :object,
              properties: %{
                id: %Schema{
                  type: :string,
                  description: "Base64url opaque per-tenant WebAuthn user handle"
                },
                name: %Schema{type: :string},
                display_name: %Schema{type: :string}
              }
            },
            pub_key_cred_params: %Schema{
              type: :array,
              items: %Schema{type: :object},
              description: "Accepted public key algorithms (ES256, RS256)"
            },
            reauth_required: %Schema{
              type: :boolean,
              description: "true when this is a subsequent (backup) enrollment"
            },
            reauth_challenge: %Schema{
              type: :object,
              nullable: true,
              description: "Present only when reauth_required is true",
              properties: %{
                challenge_id: %Schema{type: :string, format: :uuid},
                challenge: %Schema{type: :string},
                allowed_credentials: %Schema{type: :array, items: %Schema{type: :string}},
                rp_id: %Schema{type: :string},
                expires_at: %Schema{type: :string, format: :"date-time"}
              }
            }
          }
        }
      }
    })
  end

  defmodule EnrollAuthenticatorRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnrollAuthenticatorRequest",
      description:
        "Step 2 of the opt-in WebAuthn enrollment ceremony. Carries the WebAuthn " <>
          "attestation produced by navigator.credentials.create(), keyed to the " <>
          "challenge_id from step 1. All binary fields are base64url encoded. " <>
          "`reauth_assertion` is REQUIRED (and verified) when the tenant is already " <>
          "human_anchored — a fresh assertion from an existing authenticator.",
      type: :object,
      required: [:challenge_id, :attestation_object, :client_data_json, :credential_id],
      properties: %{
        challenge_id: %Schema{type: :string, format: :uuid},
        attestation_object: %Schema{type: :string, description: "Base64url attestation object"},
        client_data_json: %Schema{type: :string, description: "Base64url raw client data JSON"},
        credential_id: %Schema{type: :string, description: "Base64url credential id"},
        friendly_name: %Schema{
          type: :string,
          description:
            "Operator-supplied label (1..120 BYTES — the same unit the schema " <>
              "validates — default \"Authenticator\")"
        },
        reauth_assertion: WebAuthnAssertion
      }
    })
  end

  defmodule AuthenticatorEnrollResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthenticatorEnrollResponse",
      description: "Result of a successful authenticator enrollment.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tenant_id: %Schema{type: :string, format: :uuid},
            trust_tier: %Schema{type: :string, enum: ["agent_rooted", "human_anchored"]},
            upgraded: %Schema{
              type: :boolean,
              description: "true iff THIS call flipped the tenant to human_anchored"
            },
            capabilities: %Schema{
              type: :object,
              additionalProperties: true,
              description:
                "#505 — the trust-tier capability map for the tenant AS OF this call. " <>
                  "Enrollment is the moment the tier changes, so the newly-unlocked " <>
                  "surfaces ship with it and no re-fetch of `GET /api/v1/tenants/me` is " <>
                  "needed. Same shape as `TenantResponse.capabilities`."
            },
            authenticator: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                friendly_name: %Schema{type: :string},
                attestation_format: %Schema{type: :string},
                inserted_at: %Schema{type: :string, format: :"date-time"}
              }
            }
          }
        }
      }
    })
  end

  defmodule RevokeAuthenticatorRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RevokeAuthenticatorRequest",
      description:
        "Carries the WebAuthn assertion verified against the STORED " <>
          "revoke_authenticator challenge before the target authenticator is deleted.",
      type: :object,
      required: [:webauthn_assertion],
      properties: %{
        webauthn_assertion: WebAuthnAssertion
      }
    })
  end

  defmodule RevokeAuthenticatorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RevokeAuthenticatorResponse",
      description: "Result of a successful authenticator revocation.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tenant_id: %Schema{type: :string, format: :uuid},
            authenticator_id: %Schema{type: :string, format: :uuid},
            revoked: %Schema{type: :boolean}
          }
        }
      }
    })
  end

  defmodule AuthenticatorListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthenticatorListResponse",
      description:
        "The tenant's enrolled authenticators. Credential material " <>
          "(credential_id, public_key) is deliberately never returned — only the " <>
          "non-reversible credential_fingerprint.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              friendly_name: %Schema{type: :string},
              credential_fingerprint: %Schema{
                type: :string,
                description:
                  "Truncated SHA-256 of the credential id, as recorded in the audit " <>
                    "chain. Credential-derived and not writable by any endpoint, unlike " <>
                    "friendly_name — confirm a revocation target against this."
              },
              attestation_format: %Schema{type: :string},
              inserted_at: %Schema{type: :string, format: :"date-time"},
              last_used_at: %Schema{type: :string, format: :"date-time", nullable: true}
            }
          }
        }
      }
    })
  end

  defmodule RenameAuthenticatorRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RenameAuthenticatorRequest",
      description:
        "Request body for relabelling an enrolled authenticator. Only the display " <>
          "label is writable — credential material cannot be changed by this endpoint.",
      type: :object,
      required: [:friendly_name],
      properties: %{
        friendly_name: %Schema{
          type: :string,
          description:
            "New operator-facing label. Capped at 120 bytes (the same unit the schema " <>
              "validates); an over-long value is rejected with 422 " <>
              "friendly_name_too_long, a non-UTF-8 one with 422 friendly_name_invalid.",
          minLength: 1,
          example: "mac-mini Touch ID"
        }
      }
    })
  end

  defmodule RenameAuthenticatorResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RenameAuthenticatorResponse",
      description: "Result of a successful authenticator rename.",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tenant_id: %Schema{type: :string, format: :uuid},
            authenticator_id: %Schema{type: :string, format: :uuid},
            friendly_name: %Schema{type: :string}
          }
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
        kind: %Schema{
          type: :string,
          enum: ["work", "kb"],
          description: "work = full work-breakdown project; kb = knowledge-only scope"
        },
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

  # ---------- Coordination Bus (Epic 39) ----------

  defmodule ChannelPostRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelPostRequest",
      description:
        "Request body for posting to a repo coordination channel. agent_id and tenant_id are " <>
          "stamped server-side from the verified key and are ignored if present in the body.",
      type: :object,
      required: [:project_id, :body],
      properties: %{
        project_id: %Schema{
          type: :string,
          format: :uuid,
          description: "The channel — a project the caller's tenant owns"
        },
        body: %Schema{type: :string, description: "Free-text message (<= 16KB)"},
        key: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional working-state slot key; a repeat post from the same session upserts it. " <>
              "A handoff should pass a stable key of the form handoff:<anchor> " <>
              "(e.g. handoff:repo#812) so a same-session retry refreshes the same slot."
        },
        idempotency_key: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional client idempotency token for the KEYLESS write path (<=255 bytes). " <>
              "When supplied without a key, a repeat write with the same " <>
              "(tenant, project, agent, idempotency_key) returns the EXISTING post " <>
              "(200, created:false) instead of appending a duplicate — the same guarantee " <>
              "knowledge_create gives. Scoped per-agent, so one agent's token never collides " <>
              "with another's. Absent, the write is exactly append-only. It applies to the " <>
              "keyless append path ONLY: combining it with a key is REJECTED (422) — the " <>
              "keyed slot already dedups a same-session re-fire, so send one or the other, " <>
              "never both."
        },
        session_id: %Schema{
          type: :string,
          nullable: true,
          description: "Client-supplied session id (required when key is set)"
        },
        host: %Schema{type: :string, nullable: true, description: "Client-supplied hostname"},
        to_host: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional ADVISORY SURFACING address: the intended target host (<=255 bytes). " <>
              "Client-supplied and SPOOFABLE — a discovery hint only, NEVER authorization, " <>
              "ownership, or a delivery guarantee. It gates nothing; a post with no addressing " <>
              "is a broadcast visible to everyone on the channel."
        },
        to_capability: %Schema{
          type: :string,
          nullable: true,
          description:
            "Optional ADVISORY SURFACING address: the intended target capability, e.g. " <>
              "\"fly auth\" (<=128 bytes). Client-supplied and SPOOFABLE — a discovery hint " <>
              "only, NEVER authorization, ownership, or a delivery guarantee. Prefer this over " <>
              "to_host when the real target is a capability rather than a machine."
        },
        refs: %Schema{
          type: :array,
          nullable: true,
          description:
            "Optional bounded, typed-open LIST of reference items (max 50). Each item is " <>
              "{type, value, label?}: type is a FREE string (<=64 bytes, no allowlist), value " <>
              "<=512 bytes, optional label <=128 bytes. A secret/NUL byte in ANY item field is " <>
              "rejected (422).",
          items: %Schema{
            type: :object,
            required: [:type, :value],
            # The server rejects any item carrying a key other than type/value/label
            # (an extra key would be an unscanned exfil field) with a 422 — see
            # `ChannelPost.valid_ref_item?/1`. Publish that strictness so a client
            # following the contract does not add a field the spec calls legal.
            additionalProperties: false,
            properties: %{
              type: %Schema{type: :string, description: "Free-form ref type (<=64 bytes)"},
              value: %Schema{type: :string, description: "Ref value (<=512 bytes)"},
              label: %Schema{
                type: :string,
                nullable: true,
                description: "Optional human label (<=128 bytes)"
              }
            }
          }
        },
        supersedes: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional id of a post this one retires. The target must live in the same " <>
              "tenant+project channel, and the caller must be its author or hold role >= :user. " <>
              "A superseded post is excluded from handoff discovery and marked in the history read."
        }
      },
      example: %{
        project_id: "c3d4e5f6-a7b8-9012-cdef-123456789012",
        body: "pushed PR #107, CI green",
        key: "session_goal",
        session_id: "S1",
        refs: [
          %{type: "pr", value: "107"},
          %{type: "file", value: "lib/fly/auth.ex:42", label: "the failing call"}
        ]
      }
    })
  end

  defmodule ChannelPostResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelPostResponse",
      description: "A coordination channel post",
      type: :object,
      properties: %{
        post: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            tenant_id: %Schema{type: :string, format: :uuid},
            project_id: %Schema{type: :string, format: :uuid},
            agent_id: %Schema{type: :string, format: :uuid},
            session_id: %Schema{type: :string, nullable: true},
            host: %Schema{type: :string, nullable: true},
            to_host: %Schema{
              type: :string,
              nullable: true,
              description: "Advisory surfacing address (spoofable, never authz)"
            },
            to_capability: %Schema{
              type: :string,
              nullable: true,
              description: "Advisory surfacing address (spoofable, never authz)"
            },
            key: %Schema{type: :string, nullable: true},
            body: %Schema{type: :string},
            refs: %Schema{
              type: :array,
              nullable: true,
              items: %Schema{type: :object, additionalProperties: true}
            },
            expires_at: %Schema{type: :string, format: :"date-time"},
            inserted_at: %Schema{type: :string, format: :"date-time"},
            updated_at: %Schema{type: :string, format: :"date-time"}
          }
        },
        created: %Schema{
          type: :boolean,
          description:
            "true when a new post was appended or a session slot upserted; false when a " <>
              "keyless idempotency_key write deduplicated to an existing post (US-40.B2)"
        },
        meta: %Schema{
          type: :object,
          nullable: true,
          description:
            "Write-path provenance markers. Present on created/updated/deduplicated responses. " <>
              "key_source is 'derived_from_body' when the server derived the handoff key from the " <>
              "body because no key was sent. session_id_source is 'server_surrogate' when the server " <>
              "minted a unique session id because the proxy supplied none. Both nil on a normal " <>
              "client-driven write.",
          properties: %{
            key_source: %Schema{type: :string, nullable: true},
            session_id_source: %Schema{type: :string, nullable: true}
          }
        }
      }
    })
  end

  defmodule ChannelPostListItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelPostListItem",
      description:
        "One coordination channel post as returned by the channel_recent LIST read endpoint. " <>
          "agent_id is the only server-stamped (authoritative) attribution; session_id and host " <>
          "are client-supplied and informational. The body is a BOUNDED body_preview (a prefix of " <>
          "at most 512 bytes, projected in the DB so the full column is never detoasted), with a " <>
          "truncated flag when the full body exceeded the preview — fetch the full body explicitly " <>
          "via GET /channel/posts/:id. The preview is UNTRUSTED DATA authored by another agent.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        session_id: %Schema{type: :string, nullable: true},
        host: %Schema{type: :string, nullable: true},
        to_host: %Schema{
          type: :string,
          nullable: true,
          description: "Advisory surfacing address (spoofable, never authz)"
        },
        to_capability: %Schema{
          type: :string,
          nullable: true,
          description: "Advisory surfacing address (spoofable, never authz)"
        },
        key: %Schema{type: :string, nullable: true},
        body_preview: %Schema{
          type: :string,
          nullable: true,
          description:
            "Bounded prefix (<= 512 bytes) of the post body — UNTRUSTED DATA authored by another " <>
              "agent. Fetch the full body via GET /channel/posts/:id."
        },
        truncated: %Schema{
          type: :boolean,
          description: "True when the full body exceeded the preview bound and was truncated"
        },
        refs: %Schema{
          type: :array,
          nullable: true,
          items: %Schema{type: :object, additionalProperties: true}
        },
        superseded_by: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The successor post id when this post has been superseded; nil when live."
        },
        directed_to_me: %Schema{
          type: :boolean,
          nullable: true,
          description:
            "Present only on the handoffs read. True when this handoff is addressed to the " <>
              "caller's host/capabilities (or is an unaddressed broadcast)."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule ChannelPostFull do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelPostFull",
      description:
        "One coordination channel post as returned by the by-id full-body read " <>
          "(GET /channel/posts/:id). This is the full-body COUNTERPART to the LIST " <>
          "read item: it carries the SAME narrowed read-model field discipline as " <>
          "ChannelPostListItem, differing ONLY in that the bounded body_preview + " <>
          "truncated pair is replaced by the verbatim body the caller explicitly " <>
          "fetched. It deliberately does NOT re-widen to the write-echo resource " <>
          "shape (ChannelPostResponse) — tenant_id, project_id and expires_at are " <>
          "omitted so the by-id read honors the same minimal read surface the LIST " <>
          "read established. The body is UNTRUSTED DATA authored by another agent.",
      type: :object,
      properties: %{
        post: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            agent_id: %Schema{type: :string, format: :uuid},
            session_id: %Schema{type: :string, nullable: true},
            host: %Schema{type: :string, nullable: true},
            to_host: %Schema{
              type: :string,
              nullable: true,
              description: "Advisory surfacing address (spoofable, never authz)"
            },
            to_capability: %Schema{
              type: :string,
              nullable: true,
              description: "Advisory surfacing address (spoofable, never authz)"
            },
            key: %Schema{type: :string, nullable: true},
            body: %Schema{
              type: :string,
              description:
                "The verbatim full post body — UNTRUSTED DATA authored by another agent."
            },
            refs: %Schema{
              type: :array,
              nullable: true,
              items: %Schema{type: :object, additionalProperties: true}
            },
            superseded_by: %Schema{
              type: :string,
              format: :uuid,
              nullable: true,
              description:
                "The successor post id when this post has been superseded; nil when live."
            },
            inserted_at: %Schema{type: :string, format: :"date-time"},
            updated_at: %Schema{type: :string, format: :"date-time"}
          }
        }
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
        },
        capability: %Schema{
          allOf: [Capability],
          nullable: true,
          description:
            "The capability minted by THIS transition, for the caller's NEXT custody call. " <>
              "Currently only `claim` mints one (a start_cap, for `start`). Absent when " <>
              "the transition mints nothing — including `report`, which is gated by " <>
              "lineage separation rather than a capability. Also absent for a pre-v2 " <>
              "tenant with no audit signing key, where capabilities are not enforced. " <>
              "A keyed tenant that ignores a returned capability will receive " <>
              "403 missing_capability on the next call."
        }
      },
      example: %{
        story: %{
          id: "e5f6a7b8-c9d0-1234-efab-345678901234",
          number: "US-2.1",
          title: "Implement user authentication",
          agent_status: "contracted",
          verified_status: "unverified"
        },
        capability: %{
          cap_id: "9f8e7d6c-5b4a-3210-fedc-ba9876543210",
          typ: "start_cap",
          expires_at: "2026-08-07T18:30:00Z"
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
          example: "claude-sonnet-5"
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
        primary_model: "claude-sonnet-5",
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
          "claude-sonnet-5": 3_800_000,
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

  # ---------- Chain of Custody v2 (Epic 26) ----------

  defmodule DispatchResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DispatchResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        parent_dispatch_id: %Schema{type: :string, format: :uuid, nullable: true},
        role: %Schema{type: :string, enum: ["agent", "orchestrator", "user"]},
        lineage_path: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
        expires_at: %Schema{type: :string, format: :"date-time"},
        revoked_at: %Schema{type: :string, format: :"date-time", nullable: true}
      }
    })
  end

  defmodule CapabilityTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CapabilityTokenResponse",
      type: :object,
      properties: %{
        cap_id: %Schema{type: :string, format: :uuid},
        typ: %Schema{
          type: :string,
          enum: ["start_cap"],
          description:
            "Recovery only ever re-mints a start_cap; any other value is refused with 422 " <>
              "and recorded as a capability-forgery attempt."
        },
        story_id: %Schema{type: :string, format: :uuid},
        issued_to_lineage: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
        expires_at: %Schema{type: :string, format: :"date-time"},
        nonce: %Schema{type: :string, description: "base64url-encoded 32-byte nonce"},
        signature: %Schema{type: :string, description: "base64url-encoded ed25519 signature"}
      }
    })
  end

  defmodule SignedTreeHeadResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SignedTreeHeadResponse",
      type: :object,
      properties: %{
        tenant_id: %Schema{type: :string, format: :uuid},
        chain_position: %Schema{type: :integer},
        merkle_root: %Schema{type: :string, description: "base64url-encoded SHA-256"},
        signed_at: %Schema{type: :string, format: :"date-time"},
        signature: %Schema{type: :string, description: "base64url-encoded ed25519 signature"}
      }
    })
  end

  defmodule AuditChainEntryResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditChainEntryResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        chain_position: %Schema{type: :integer},
        action: %Schema{type: :string},
        entity_type: %Schema{type: :string},
        entity_id: %Schema{type: :string, format: :uuid, nullable: true},
        actor_lineage: %Schema{type: :array, items: %Schema{type: :string}},
        payload: %Schema{type: :object},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule VerificationRunResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerificationRunResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        story_id: %Schema{type: :string, format: :uuid},
        commit_sha: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["pending", "running", "pass", "fail", "error"]},
        runner_type: %Schema{type: :string, nullable: true},
        ac_results: %Schema{type: :object},
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        completed_at: %Schema{type: :string, format: :"date-time", nullable: true}
      }
    })
  end

  defmodule AcceptanceCriterionResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AcceptanceCriterionResponse",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        ac_id: %Schema{type: :string},
        description: %Schema{type: :string},
        verification_criterion: %Schema{type: :object},
        status: %Schema{type: :string, enum: ["pending", "verified", "failed", "unverifiable"]},
        verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        evidence_path: %Schema{type: :string, nullable: true}
      }
    })
  end

  # ---------- Per-tenant BYO LLM config + usage (Epic 28 residual, #179) ----------

  defmodule LlmConfigUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LlmConfigUpdateRequest",
      description:
        "Request body for `PATCH /api/v1/tenants/me/llm-config`. Sets the tenant's " <>
          "OWN Anthropic API key and OpenAI embedding key (both encrypted at rest, " <>
          "never returned) and the granular per-operation model choices. Any subset " <>
          "of fields may be sent; omitting a key leaves the existing key untouched. " <>
          "Model ids are free-form (any model the key permits) — not an allow-list.",
      type: :object,
      properties: %{
        api_key: %Schema{
          type: :string,
          writeOnly: true,
          description: "Anthropic API key (write-only; stored encrypted, never returned)"
        },
        extraction_model: %Schema{
          type: :string,
          nullable: true,
          description: "Model id for knowledge extraction (null → server default)"
        },
        classification_model: %Schema{
          type: :string,
          nullable: true,
          description: "Model id for category classification (null → server default)"
        },
        merge_model: %Schema{
          type: :string,
          nullable: true,
          description: "Model id for article merge synthesis (null → server default)"
        },
        embedding_api_key: %Schema{
          type: :string,
          writeOnly: true,
          description:
            "OpenAI-compatible embedding API key (write-only; stored encrypted, never " <>
              "returned). Mandatory BYO — without it the tenant's articles are not " <>
              "vector-searchable."
        },
        embedding_model: %Schema{
          type: :string,
          nullable: true,
          description: "Embedding model id (null → server default `text-embedding-3-small`)"
        },
        chat_provider: %Schema{
          type: :string,
          enum: ["anthropic", "openai_compatible"],
          nullable: true,
          description:
            "Which provider serves the CHAT surface (extraction / classification / " <>
              "merge / content extraction / memory promotion). Null or `anthropic` " <>
              "keeps the hardcoded Anthropic endpoint and identical behaviour."
        },
        chat_base_url: %Schema{
          type: :string,
          nullable: true,
          description:
            "API base of an OpenAI-compatible server (the client appends " <>
              "`/chat/completions`). Required when `chat_provider` is " <>
              "`openai_compatible`. PROBED with a trivial completion before it is " <>
              "saved; a probe failure is a 422 and nothing is persisted."
        },
        chat_api_key: %Schema{
          type: :string,
          writeOnly: true,
          description:
            "Credential for `chat_base_url` (write-only; stored encrypted, never " <>
              "returned). SEPARATE from `api_key` — the Anthropic key is never sent " <>
              "to a tenant-supplied host."
        },
        acknowledge_key_transmission: %Schema{
          type: :boolean,
          writeOnly: true,
          description:
            "Required when changing `chat_base_url` WITHOUT supplying a matching " <>
              "`chat_api_key`: explicitly acknowledges that the already-stored key " <>
              "will be transmitted to the new host. Not persisted."
        }
      },
      example: %{
        api_key: "sk-ant-...",
        extraction_model: "claude-haiku-4-5-20251001",
        classification_model: "claude-sonnet-4-5-20250929",
        merge_model: "claude-haiku-4-5-20251001",
        embedding_api_key: "sk-...",
        embedding_model: "text-embedding-3-small"
      }
    })
  end

  defmodule LlmConfigResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LlmConfigResponse",
      description:
        "The tenant's LLM configuration. NEVER includes any API key itself — only " <>
          "whether each key is set (`has_api_key` / `has_embedding_key`) and masked " <>
          "last-4 hints (`api_key_hint` / `embedding_api_key_hint`).",
      type: :object,
      properties: %{
        has_api_key: %Schema{
          type: :boolean,
          description: "Whether an Anthropic key is configured"
        },
        api_key_hint: %Schema{
          type: :string,
          nullable: true,
          description: "Masked last-4 hint (e.g. \"...aB3d\"); never the full key"
        },
        extraction_model: %Schema{type: :string, nullable: true},
        classification_model: %Schema{type: :string, nullable: true},
        merge_model: %Schema{type: :string, nullable: true},
        has_embedding_key: %Schema{
          type: :boolean,
          description: "Whether an OpenAI embedding key is configured"
        },
        embedding_api_key_hint: %Schema{
          type: :string,
          nullable: true,
          description: "Masked last-4 hint for the embedding key; never the full key"
        },
        embedding_model: %Schema{type: :string, nullable: true},
        chat_provider: %Schema{
          type: :string,
          description: "`anthropic` (default) or `openai_compatible`"
        },
        chat_base_url: %Schema{
          type: :string,
          nullable: true,
          description:
            "The configured OpenAI-compatible API base, echoed back. NOT a secret — " <>
              "it is the tenant's own declared host and naming it is the point."
        },
        has_chat_key: %Schema{
          type: :boolean,
          description: "Whether a credential for `chat_base_url` is configured"
        },
        chat_api_key_hint: %Schema{
          type: :string,
          nullable: true,
          description: "Masked last-4 hint for the chat key; never the full key"
        }
      },
      example: %{
        has_api_key: true,
        api_key_hint: "...aB3d",
        extraction_model: "claude-haiku-4-5-20251001",
        classification_model: "claude-sonnet-4-5-20250929",
        merge_model: nil,
        has_embedding_key: true,
        embedding_api_key_hint: "...Xy9z",
        embedding_model: "text-embedding-3-small",
        chat_provider: "anthropic",
        chat_base_url: nil,
        has_chat_key: false,
        chat_api_key_hint: nil
      }
    })
  end

  defmodule LlmUsageMeta do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LlmUsageMeta",
      description:
        "Offset/limit pagination metadata for the LLM usage summary, plus the " <>
          "EFFECTIVE date window actually applied. Advance `offset` by `limit` to " <>
          "enumerate `total_count` grouped rows. When `from` is omitted it defaults " <>
          "to a 90-day lookback (echoed here so callers can detect the truncation).",
      type: :object,
      properties: %{
        limit: %Schema{type: :integer, description: "Effective page size (rows returned)"},
        offset: %Schema{type: :integer, description: "Rows skipped"},
        total_count: %Schema{type: :integer, description: "Total grouped rows across all pages"},
        from: %Schema{
          type: :string,
          format: :"date-time",
          description: "Effective lower bound applied (defaults to now − 90 days when omitted)"
        },
        to: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Effective upper bound applied (null = open-ended / now)"
        }
      },
      example: %{
        limit: 50,
        offset: 0,
        total_count: 3,
        from: "2026-04-04T00:00:00Z",
        to: nil
      }
    })
  end

  defmodule LlmUsageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LlmUsageResponse",
      description:
        "Per-tenant LLM token-usage summary, grouped by operation + model + " <>
          "provider + source_type + day over an optional date range. Record-only " <>
          "— there is no budget enforcement.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              day: %Schema{type: :string, format: :"date-time"},
              operation: %Schema{
                type: :string,
                enum: ["extraction", "classification", "merge", "embedding"]
              },
              model: %Schema{type: :string},
              # US-41.3 (AC-41.3.6): the ledger is provider-attributed, so a
              # tenant's own OpenAI-compatible endpoint spend is distinguishable
              # from Anthropic's and from embedding spend.
              provider: %Schema{
                type: :string,
                enum: ["anthropic", "openai_compatible", "embedding"],
                description:
                  "Which provider surface the tokens were spent on. Rows recorded " <>
                    "before US-41.3 are attributed by their operation."
              },
              source_type: %Schema{type: :string, nullable: true},
              input_tokens: %Schema{type: :integer},
              output_tokens: %Schema{type: :integer},
              event_count: %Schema{type: :integer}
            }
          }
        },
        meta: LlmUsageMeta
      }
    })
  end

  # ---------- Agent Memory (Epic 28, US-28.3) ----------

  defmodule Memory do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Memory",
      description:
        "A single agent memory. Long-term memories carry `text`; session " <>
          "memories carry `session_id`/`role`/`content`/`expires_at`. The raw " <>
          "embedding vector is never returned.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tier: %Schema{type: :string, enum: ["long_term", "session"]},
        tenant_id: %Schema{type: :string, format: :uuid},
        subject_id: %Schema{type: :string},
        project_id: %Schema{type: :string, format: :uuid, nullable: true},
        text: %Schema{type: :string, nullable: true},
        confidence: %Schema{type: :number, format: :float, nullable: true},
        source: %Schema{type: :string, enum: ["explicit", "promoted"], nullable: true},
        source_session_id: %Schema{type: :string, nullable: true},
        tags: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        superseded_by: %Schema{type: :string, format: :uuid, nullable: true},
        session_id: %Schema{type: :string, nullable: true},
        role: %Schema{
          type: :string,
          enum: ["user", "assistant", "system", "fact"],
          nullable: true
        },
        content: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true, nullable: true},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        seq: %Schema{type: :integer, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
      }
    })
  end

  defmodule MemoryCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryCreateRequest",
      description:
        "Params for POST /memory. Scope (tenant_id/subject_id) is derived from the " <>
          "API key — any tenant_id/subject_id in the body is ignored.",
      type: :object,
      properties: %{
        tier: %Schema{
          type: :string,
          enum: ["long_term", "session"],
          description: "Defaults to long_term."
        },
        text: %Schema{type: :string, description: "Long-term memory content (tier=long_term)."},
        confidence: %Schema{type: :number, format: :float, nullable: true},
        tags: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
        source_session_id: %Schema{type: :string, nullable: true},
        session_id: %Schema{type: :string, description: "Session id (tier=session)."},
        role: %Schema{type: :string, enum: ["user", "assistant", "system", "fact"]},
        content: %Schema{type: :string, description: "Session turn content (tier=session)."},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Prune deadline (tier=session)."
        },
        metadata: %Schema{
          type: :object,
          additionalProperties: true,
          nullable: true,
          description:
            "Optional: arbitrary structured metadata to attach to the memory (either tier)."
        },
        project_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional project scope (a UUID PARTITION key, NOT an isolation boundary). " <>
              "Absent/blank writes a tenant-wide (global) memory; a malformed value is " <>
              "rejected with a 422 invalid_project_id."
        }
      }
    })
  end

  defmodule MemoryRecallRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryRecallRequest",
      description: "Params for POST /memory/recall. Query supplied in the body.",
      type: :object,
      properties: %{
        query: %Schema{type: :string, description: "Text to embed / match against."},
        limit: %Schema{
          type: :integer,
          description: "Max results, clamped to the vector-search max (no silent hard cap)."
        },
        include_superseded: %Schema{type: :boolean, description: "Default false."},
        project_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional project scope (a UUID PARTITION key, NOT an isolation boundary). " <>
              "Recall returns the merged global ∪ active-project set; absent/blank means " <>
              "global-only. A malformed value is rejected with a 422 invalid_project_id."
        }
      }
    })
  end

  defmodule MemoryPromoteRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryPromoteRequest",
      description:
        "Params for POST /memory/promote. Scope (tenant_id/subject_id) is derived " <>
          "from the API key — only `session_id` is read from the body.",
      type: :object,
      required: [:session_id],
      properties: %{
        session_id: %Schema{
          type: :string,
          description: "The session to promote into long-term memory."
        }
      }
    })
  end

  defmodule MemoryPromoteResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryPromoteResponse",
      description:
        "Confirmation that a session→long-term promotion was enqueued. The reference " <>
          "is the caller's own tenant-scoped `session_id` (the promotion is unique per " <>
          "(tenant, subject, session)); the internal Oban job id is deliberately NOT " <>
          "exposed — it is a system-wide monotonic counter that would leak a " <>
          "cross-tenant throughput side-channel.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            session_id: %Schema{
              type: :string,
              description: "The session whose promotion was enqueued (the work reference)."
            },
            status: %Schema{type: :string, enum: ["enqueued"]}
          }
        }
      }
    })
  end

  defmodule MemoryResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryResponse",
      description: "A single memory wrapped in `data`.",
      type: :object,
      properties: %{data: Memory}
    })
  end

  defmodule MemoryGraduateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryGraduateRequest",
      description:
        "Params for POST /memory/graduate (#411 Gap 3). Scope (tenant_id/subject_id) is " <>
          "derived from the API key — only `memory_id` and the optional `re_scope` are " <>
          "read from the body.",
      type: :object,
      required: [:memory_id],
      properties: %{
        memory_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "UUID of the caller's OWN long-term memory to graduate into a knowledge article."
        },
        re_scope: %Schema{
          type: :string,
          enum: ["inherit", "global"],
          description:
            "Article scope. `inherit` (default) keeps the memory's own `project_id` " <>
              "(project memory → project article, global memory → global article). " <>
              "`global` promotes a PROJECT memory to a tenant-wide (project_id: null) " <>
              "article — only valid on the memory's FIRST graduation."
        }
      }
    })
  end

  defmodule MemoryGraduateResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryGraduateResponse",
      description:
        "Result of graduating a memory into a durable knowledge article. `verdict` is the " <>
          "novelty-gate outcome; `created` is true only when a new article was materialized " <>
          "(`created`/`gated_to_draft`), false for a dedup (`duplicate`/`deduplicated`). The " <>
          "`article` is a body-less summary — fetch the full body via GET /articles/:id.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            verdict: %Schema{
              type: :string,
              enum: ["created", "gated_to_draft", "duplicate", "deduplicated"],
              description: "The novelty-gate verdict for the graduated content."
            },
            created: %Schema{
              type: :boolean,
              description: "Whether a NEW article (published or review draft) was materialized."
            },
            article: %Schema{
              type: :object,
              description: "Body-less summary of the resulting (created or canonical) article."
            }
          }
        }
      }
    })
  end

  defmodule MemoryListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryListResponse",
      description: "A paginated list of memories.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Memory},
        meta: %Schema{
          type: :object,
          properties: %{
            total_count: %Schema{type: :integer},
            limit: %Schema{type: :integer},
            offset: %Schema{type: :integer}
          }
        }
      }
    })
  end

  defmodule MemoryRecallResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryRecallResponse",
      description:
        "Recall results with pinned meta. `score` is null on the text-match " <>
          "fallback path; `meta.fallback`/`meta.reason` flag degradation and " <>
          "`meta.underfilled` a short page. On a SEMANTIC path that scans the HNSW " <>
          "index `meta.ann_iterative_scan` additionally discloses whether the vector " <>
          "read ran with pgvector's `hnsw.iterative_scan` — the same field, values and " <>
          "meaning `/knowledge/search` returns.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              memory: Memory,
              score: %Schema{type: :number, format: :float, nullable: true}
            }
          }
        },
        meta: %Schema{
          type: :object,
          properties: %{
            total_count: %Schema{type: :integer},
            fallback: %Schema{type: :boolean},
            reason: %Schema{type: :string, nullable: true},
            underfilled: %Schema{type: :boolean},
            ann_iterative_scan: %Schema{
              type: :string,
              enum: ["off", "applied", "unavailable"],
              description:
                "Present only for a recall that SCANS the HNSW index — absent on the " <>
                  "ILIKE fallback (no vector read) AND on an `include_superseded: true` " <>
                  "side-table recall (an exact bounded top-k sort, no index scan), so " <>
                  "absence does NOT imply the fallback path (`meta.fallback` does): " <>
                  "whether this recall's vector read ran with pgvector's " <>
                  "`hnsw.iterative_scan`. `off` = not enabled on this instance (the " <>
                  "default). `applied` = enabled and in force. `unavailable` = enabled, " <>
                  "but the read fell back to a single index batch — your `tenant_id` is " <>
                  "applied AFTER that batch, so results may be INCOMPLETE and a short " <>
                  "page is NOT evidence your memory scope is sparse (`meta.underfilled` " <>
                  "cannot tell the two apart). It says nothing about SUBJECT-level " <>
                  "under-return: `subject_id` is filtered outside the index scan, " <>
                  "bounded by the over-fetch pool and identical under `applied` — " <>
                  "`meta.underfilled` is the only signal for that. Read " <>
                  "`ann_iterative_scan_reason` for WHICH cause: an " <>
                  "inconclusive capability probe self-heals on the next conclusive one, " <>
                  "while a pgvector that does not support the setting stands until the " <>
                  "extension is upgraded. Same values and meaning as the " <>
                  "`/knowledge/search` field of the same name."
            },
            ann_iterative_scan_reason: %Schema{
              type: :string,
              description:
                "Present ONLY alongside `ann_iterative_scan: \"unavailable\"`: a " <>
                  "non-sensitive explanation of the degraded vector read."
            }
          }
        }
      }
    })
  end

  defmodule RecallContextRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecallContextRequest",
      description:
        "Params for POST /recall (merged memory ∪ knowledge recall, #411 Gap 2). " <>
          "Query supplied in the body; scope (tenant_id/subject_id) is derived from the " <>
          "API key, never the body.",
      type: :object,
      properties: %{
        query: %Schema{
          type: :string,
          description: "Text to embed / match against on BOTH the memory and knowledge sides."
        },
        limit: %Schema{
          type: :integer,
          description:
            "Overall merged page size, clamped to [1, 50] (default 10). Applied " <>
              "per-source first, then to the merged, re-ranked list."
        },
        project_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional project scope (a UUID PARTITION key, NOT an isolation boundary). " <>
              "Present → both sides return the merged global ∪ that-project set; " <>
              "absent/blank → global-only. A malformed value is a 422 invalid_project_id."
        }
      }
    })
  end

  defmodule RecallContextResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecallContextResponse",
      description:
        "Merged recall: `data` is the re-ranked union across memory + knowledge (each " <>
          "item tagged `source`, sorted by a heuristically-comparable `score` DESC — " <>
          "`meta.results_ranking` is `heuristic_cross_source`), with the untouched " <>
          "per-source `memory` and `knowledge` envelopes for re-ranking, plus `meta` " <>
          "(counts + degraded flag). Cross-source scores are heuristic, not calibrated: " <>
          "memory `score` is ABSOLUTE cosine similarity in [0,1] (null on the fallback " <>
          "path); knowledge `score` is a POOL-NORMALIZED keyword+semantic score (biases " <>
          "knowledge upward in the default order). The knowledge `article`/`data` items " <>
          "are combined-search SUMMARIES (id/title/category/tags/score + a truncated " <>
          "snippet) — the same shape `/knowledge/search` returns, NOT full bodies or " <>
          "linked references; call `/knowledge/context` for those.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          description: "Merged, re-ranked results across both sources.",
          items: %Schema{
            type: :object,
            properties: %{
              source: %Schema{type: :string, enum: ["memory", "knowledge"]},
              score: %Schema{type: :number, format: :float, nullable: true},
              memory: %Schema{
                type: :object,
                nullable: true,
                description: "Present on `source: memory` items (see Memory schema)."
              },
              article: %Schema{
                type: :object,
                nullable: true,
                description:
                  "Present on `source: knowledge` items — the combined-search summary " <>
                    "(id/title/category/tags/score + truncated snippet), the same " <>
                    "whitelisted shape `/knowledge/search` returns."
              }
            }
          }
        },
        memory: %Schema{
          type: :object,
          description:
            "The unchanged /memory/recall envelope (data + meta). Its " <>
              "`meta.ann_iterative_scan` describes THIS half's vector read only — the " <>
              "two halves run sequentially and each resolves the backend capability " <>
              "independently, so they may legitimately differ within one response.",
          properties: %{
            data: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  memory: Memory,
                  score: %Schema{type: :number, format: :float, nullable: true}
                }
              }
            },
            meta: %Schema{type: :object}
          }
        },
        knowledge: %Schema{
          type: :object,
          description:
            "The combined-search envelope (data + meta). Each `data` item is the " <>
              "whitelisted summary shape (id/title/category/tags/score + truncated " <>
              "snippet), NOT the raw internal result map.",
          properties: %{
            data: %Schema{type: :array, items: %Schema{type: :object}},
            meta: %Schema{type: :object}
          }
        },
        meta: %Schema{
          type: :object,
          properties: %{
            query: %Schema{type: :string},
            project_id: %Schema{type: :string, format: :uuid, nullable: true},
            total_count: %Schema{type: :integer},
            memory_count: %Schema{type: :integer},
            knowledge_count: %Schema{type: :integer},
            degraded: %Schema{
              type: :boolean,
              description:
                "True when EITHER half degraded: the knowledge side errored or fell back " <>
                  "to keyword-only, OR the memory heavy-read pool was shed under the " <>
                  "per-tenant cap (empty by capacity, never a whole-endpoint 429)."
            },
            degraded_reason: %Schema{
              type: :string,
              nullable: true,
              description:
                "Bounded, non-sensitive tag naming WHY the merged recall degraded " <>
                  "(e.g. `heavy_read_overloaded`, `no_embedding_key`, `invalid_weights`), " <>
                  "or `null` when healthy. Lets a caller tell a scope-empty half from a " <>
                  "fault-empty one without parsing the per-source envelopes."
            },
            results_ranking: %Schema{
              type: :string,
              description:
                "Stable tag (`heuristic_cross_source`) warning that the merged `data` " <>
                  "order mixes memory's absolute cosine with knowledge's pool-normalized " <>
                  "score and is NOT a calibrated cross-source ranking."
            }
          }
        }
      }
    })
  end

  defmodule MemoryDeleteResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemoryDeleteResponse",
      description: "Confirmation that a memory was forgotten.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            deleted: %Schema{type: :boolean}
          }
        }
      }
    })
  end

  # ---------- Context Retriever (Epic 30, US-30.4) ----------

  defmodule EntityDefinitionField do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EntityDefinitionField",
      description:
        "A single declared field on an entity definition. `name` must be a column " <>
          "in the SERVER per-source allowlist; `type` is one of the allowed field " <>
          "types. `filterable`/`searchable` gate which tools the field generates.",
      type: :object,
      required: [:name, :type],
      properties: %{
        name: %Schema{type: :string, description: "Allowlisted column name (snake_case)."},
        type: %Schema{
          type: :string,
          enum: ["string", "integer", "boolean", "float", "datetime"]
        },
        filterable: %Schema{type: :boolean, description: "Generate a filter tool. Default false."},
        searchable: %Schema{
          type: :boolean,
          description: "Contribute to the entity's full-text search tool. Default false."
        }
      }
    })
  end

  defmodule EntityDefinition do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EntityDefinition",
      description:
        "A tenant-authored entity definition: a named, typed view over a " <>
          "loopctl-internal backing source (projects/stories/epics). Its declared " <>
          "fields ARE the executor's field allowlist.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        tenant_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        backing_source: %Schema{type: :string, enum: ["projects", "stories", "epics"]},
        fields: %Schema{type: :array, items: EntityDefinitionField},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule EntityDefinitionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EntityDefinitionRequest",
      description:
        "Params for POST/PATCH /entities. `tenant_id` is derived from the API key " <>
          "and any tenant_id in the body is ignored. On PATCH, omitted top-level " <>
          "fields keep their current value.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Entity name, unique per tenant."},
        backing_source: %Schema{type: :string, enum: ["projects", "stories", "epics"]},
        fields: %Schema{type: :array, items: EntityDefinitionField}
      }
    })
  end

  defmodule EntityDefinitionResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EntityDefinitionResponse",
      description: "A single entity definition wrapped in `data`.",
      type: :object,
      properties: %{data: EntityDefinition}
    })
  end

  defmodule EntityDefinitionListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EntityDefinitionListResponse",
      description: "The calling tenant's entity definitions.",
      type: :object,
      properties: %{data: %Schema{type: :array, items: EntityDefinition}}
    })
  end

  defmodule RetrieveToolSpec do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RetrieveToolSpec",
      description:
        "A generated agent tool spec (from the tenant's entity definitions). " <>
          "`input_schema` is a JSON Schema for the tool's params; `metadata` is the " <>
          "executor dispatch contract (entity/backing_source/field/operation).",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Tool name, prefixed `cr_`."},
        description: %Schema{type: :string},
        input_schema: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule RetrieveToolsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RetrieveToolsResponse",
      description:
        "The generated tool specs for the CALLING tenant only — another tenant's " <>
          "entities never appear.",
      type: :object,
      properties: %{data: %Schema{type: :array, items: RetrieveToolSpec}}
    })
  end

  defmodule RetrieveRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RetrieveRequest",
      description:
        "Params for POST /retrieve/:entity. `field` + `op` select the operation " <>
          "(`filter` needs the matched field's value in `value`; `search` needs " <>
          "`query`). Any `tenant_id` in the body is ignored (scope is from the key).",
      type: :object,
      properties: %{
        field: %Schema{type: :string, description: "Field to filter on (op=filter)."},
        op: %Schema{type: :string, enum: ["filter", "search"], description: "Operation."},
        operation: %Schema{
          type: :string,
          enum: ["filter", "search"],
          description: "Alias for `op`."
        },
        value: %Schema{description: "Filter value (op=filter)."},
        query: %Schema{type: :string, description: "Search string (op=search)."},
        limit: %Schema{type: :integer, description: "Page size (clamped to the server max)."},
        offset: %Schema{type: :integer, description: "Records to skip (clamped)."}
      }
    })
  end

  defmodule RetrieveResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RetrieveResponse",
      description:
        "A page of allowlisted-column result maps plus pagination meta. Only the " <>
          "entity's declared columns appear in each result.",
      type: :object,
      properties: %{
        results: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        },
        meta: %Schema{
          type: :object,
          properties: %{
            total_count: %Schema{type: :integer},
            limit: %Schema{type: :integer},
            offset: %Schema{type: :integer}
          }
        }
      }
    })
  end
end
