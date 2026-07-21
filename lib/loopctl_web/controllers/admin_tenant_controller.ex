defmodule LoopctlWeb.AdminTenantController do
  @moduledoc """
  Controller for superadmin tenant management endpoints.

  All endpoints require a superadmin API key (exact_role: :superadmin).
  Uses AdminRepo via the Tenants context for cross-tenant access.

  - `GET /api/v1/admin/tenants` — list all tenants with stats
  - `GET /api/v1/admin/tenants/:id` — tenant detail with full stats
  - `PATCH /api/v1/admin/tenants/:id` — update tenant (partial settings merge)
  - `POST /api/v1/admin/tenants/:id/suspend` — suspend tenant
  - `POST /api/v1/admin/tenants/:id/activate` — re-activate tenant
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.WebAuthn.Reauth
  alias LoopctlWeb.AuditContext

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

  # Break-glass custody-halt recovery is a Chain of Custody v2 L6 control:
  # even a compromised superadmin key MUST prove possession of the tenant's
  # enrolled hardware authenticator. The purpose string is a compile-time
  # constant (never user input) and is DISTINCT from the audit-key rotation
  # purpose, so a challenge minted for one ceremony cannot be replayed against
  # the other — `Reauth.consume_challenge/3` scopes by `(tenant_id, purpose)`.
  @clear_halt_purpose "clear_custody_halt"

  tags(["Admin"])

  operation(:index,
    summary: "List all tenants (admin)",
    description: "Lists all tenants with summary stats. Requires superadmin.",
    parameters: [
      status: [in: :query, type: :string, description: "Filter by status"],
      search: [in: :query, type: :string, description: "Search by name or slug"],
      page: [in: :query, type: :integer, description: "Page number"],
      page_size: [in: :query, type: :integer, description: "Items per page"]
    ],
    responses: %{
      200 =>
        {"Tenant list", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:show,
    summary: "Get tenant detail (admin)",
    description: "Returns full tenant detail with all summary stats.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 =>
        {"Tenant detail", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update tenant (admin)",
    description: "Updates a tenant. Settings are partially merged.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    request_body:
      {"Update params", "application/json",
       %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
    responses: %{
      200 =>
        {"Updated tenant", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:suspend,
    summary: "Suspend tenant (admin)",
    description: "Suspends a tenant. Returns 422 if already suspended.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 =>
        {"Tenant suspended", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Already suspended", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:activate,
    summary: "Activate tenant (admin)",
    description: "Activates a tenant. Returns 422 if already active.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 =>
        {"Tenant activated", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 => {"Already active", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/admin/tenants

  Lists all tenants with summary stats. Supports filtering by status and
  search by name or slug.
  """
  def index(conn, params) do
    opts =
      []
      |> maybe_put_status(:status, params["status"])
      |> maybe_put(:search, params["search"])
      |> maybe_put_integer(:page, params["page"])
      |> maybe_put_integer(:page_size, params["page_size"])

    {:ok, result} = Tenants.list_tenants_admin(opts)

    json(conn, %{
      data: Enum.map(result.data, &tenant_with_stats_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  GET /api/v1/admin/tenants/:id

  Returns full tenant detail with all summary stats.
  """
  def show(conn, %{"id" => id}) do
    with {:ok, data} <- Tenants.get_tenant_admin(id) do
      json(conn, %{tenant: tenant_detail_json(data)})
    end
  end

  @doc """
  PATCH /api/v1/admin/tenants/:id

  Updates a tenant. Settings are partially merged (provided keys override,
  unspecified keys preserved).
  """
  def update(conn, %{"id" => id} = params) do
    with {:ok, %{tenant: tenant}} <- Tenants.get_tenant_admin(id) do
      audit = AuditContext.from_conn(conn)

      case Tenants.update_tenant_admin(tenant, params) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_updated",
            actor_type: Keyword.get(audit, :actor_type, "superadmin"),
            actor_id: Keyword.fetch!(audit, :actor_id),
            actor_label: Keyword.fetch!(audit, :actor_label),
            new_state: %{
              "name" => updated.name,
              "email" => updated.email,
              "settings" => updated.settings
            }
          })

          {:ok, data} = Tenants.get_tenant_admin(updated.id)
          json(conn, %{tenant: tenant_detail_json(data)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  POST /api/v1/admin/tenants/:id/suspend

  Suspends a tenant. Returns 422 if already suspended.
  """
  def suspend(conn, %{"id" => id}) do
    with {:ok, %{tenant: tenant}} <- Tenants.get_tenant_admin(id),
         :ok <- check_not_status(tenant, :suspended, "Tenant is already suspended") do
      audit = AuditContext.from_conn(conn)

      case Tenants.suspend_tenant(tenant) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_suspended",
            actor_type: Keyword.get(audit, :actor_type, "superadmin"),
            actor_id: Keyword.fetch!(audit, :actor_id),
            actor_label: Keyword.fetch!(audit, :actor_label),
            new_state: %{"status" => "suspended"}
          })

          {:ok, data} = Tenants.get_tenant_admin(updated.id)
          json(conn, %{tenant: tenant_detail_json(data)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  POST /api/v1/admin/tenants/:id/activate

  Activates a tenant. Returns 422 if already active.
  """
  def activate(conn, %{"id" => id}) do
    with {:ok, %{tenant: tenant}} <- Tenants.get_tenant_admin(id),
         :ok <- check_not_status(tenant, :active, "Tenant is already active") do
      audit = AuditContext.from_conn(conn)

      case Tenants.activate_tenant(tenant) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_activated",
            actor_type: Keyword.get(audit, :actor_type, "superadmin"),
            actor_id: Keyword.fetch!(audit, :actor_id),
            actor_label: Keyword.fetch!(audit, :actor_label),
            new_state: %{"status" => "active"}
          })

          {:ok, data} = Tenants.get_tenant_admin(updated.id)
          json(conn, %{tenant: tenant_detail_json(data)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # --- JSON serializers ---

  defp tenant_with_stats_json(%{tenant: tenant} = data) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      email: tenant.email,
      status: tenant.status,
      project_count: data.project_count,
      story_count: data.story_count,
      agent_count: data.agent_count,
      api_key_count: data.api_key_count,
      inserted_at: tenant.inserted_at
    }
  end

  defp tenant_detail_json(%{tenant: tenant} = data) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      email: tenant.email,
      settings: tenant.settings,
      status: tenant.status,
      project_count: data.project_count,
      story_count: data.story_count,
      epic_count: data.epic_count,
      agent_count: data.agent_count,
      api_key_count: data.api_key_count,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }
  end

  # --- Helpers ---

  defp check_not_status(tenant, status, message) do
    if tenant.status == status do
      {:error, :unprocessable_entity, message}
    else
      :ok
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_status(opts, _key, nil), do: opts

  defp maybe_put_status(opts, key, value) when is_binary(value) do
    case value do
      "active" -> Keyword.put(opts, key, :active)
      "suspended" -> Keyword.put(opts, key, :suspended)
      "deactivated" -> Keyword.put(opts, key, :deactivated)
      _ -> opts
    end
  end

  defp maybe_put_integer(opts, _key, nil), do: opts

  defp maybe_put_integer(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> Keyword.put(opts, key, n)
      :error -> opts
    end
  end

  defp maybe_put_integer(opts, key, value) when is_integer(value) do
    Keyword.put(opts, key, value)
  end

  defp ceil_div(numerator, denominator), do: ceil(numerator / denominator)

  @doc """
  POST /api/v1/admin/tenants/:id/bootstrap-audit-key

  Generates the initial ed25519 audit keypair for a legacy tenant that
  predates the Chain of Custody v2 signup ceremony. Refuses to run if
  the tenant already has a key — use rotate-audit-key for that.
  """
  def bootstrap_audit_key(conn, %{"id" => id}) do
    case Tenants.bootstrap_audit_key(id) do
      {:ok, tenant} ->
        api_key = conn.assigns.current_api_key

        Loopctl.AuditChain.append(tenant.id, %{
          action: "audit_key_bootstrapped",
          actor_lineage: [],
          entity_type: "tenant",
          entity_id: tenant.id,
          payload: %{"bootstrapped_by" => api_key.id}
        })

        json(conn, %{
          data: %{
            tenant_id: tenant.id,
            audit_signing_public_key: Base.encode64(tenant.audit_signing_public_key),
            message: "Audit keypair generated. Trust layers L1, L2, L5, L6 are now active."
          }
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: %{message: "Not found", status: 404}})

      {:error, :key_already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            message: "Tenant already has an audit key. Use rotate-audit-key instead.",
            status: 409
          }
        })

      {:error, {:audit_key_storage_failed, _reason}} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{message: "Failed to store the audit key. Please retry.", status: 500}
        })

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{message: "Key bootstrap failed", status: 500}})
    end
  end

  operation(:clear_halt_challenge,
    summary: "Issue a break-glass clear-halt reauth challenge (admin)",
    description:
      "Step 1 of the challenge-bound WebAuthn reauthentication ceremony for " <>
        "break-glass custody-halt recovery. Issues an authentication challenge bound " <>
        "to the target tenant's enrolled root authenticators, stores it server-side " <>
        "(single-use, short TTL) and returns the opaque `challenge_id`, the base64url " <>
        "challenge bytes, and the allowed credential ids. Requires superadmin.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    responses: %{
      200 => {"Reauth challenge", "application/json", Schemas.ReauthChallengeResponse},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"No enrolled authenticators", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/admin/tenants/:id/clear-halt/challenge

  Step 1 of the break-glass reauth ceremony. Mints a server-side,
  single-use, TTL-bounded authentication challenge bound to the TARGET
  tenant (the path `:id`) and returns the opaque handle plus allowed
  credential ids. Superadmin-only (controller-level `RequireRole` plug).

  This is a cross-tenant superadmin operation, so there is NO ownership
  check: the target tenant is the path `:id`, and tenant isolation holds
  because the challenge is stored under that `tenant_id` and can only be
  consumed against the same `tenant_id` in `clear_halt/2`.
  """
  def clear_halt_challenge(conn, %{"id" => tenant_id}) do
    case Reauth.issue_challenge(tenant_id, @clear_halt_purpose) do
      {:ok, issued} ->
        conn
        |> put_status(:ok)
        |> json(%{
          data: %{
            challenge_id: issued.challenge_id,
            challenge: issued.challenge,
            allowed_credentials: issued.allowed_credentials,
            rp_id: issued.rp_id,
            expires_at: issued.expires_at
          }
        })

      {:error, :no_authenticators} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            message:
              "Tenant has no enrolled root authenticator to authorize break-glass recovery",
            code: "no_authenticators",
            status: 422
          }
        })

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{message: "Failed to issue reauth challenge", status: 500}})
    end
  end

  operation(:clear_halt,
    summary: "Clear a tenant custody halt (break-glass, admin)",
    description:
      "Step 2 of the challenge-bound WebAuthn reauthentication ceremony. Verifies " <>
        "the assertion against the STORED challenge from step 1 (challenge binding, " <>
        "origin, RP-ID, signature against the enrolled COSE key, sign-counter " <>
        "regression) and, on success, clears the tenant's custody halt. The " <>
        "assertion is single-use — one challenge authorizes exactly one attempt. " <>
        "Requires superadmin.",
    parameters: [id: [in: :path, type: :string, description: "Tenant UUID"]],
    request_body: {"WebAuthn assertion", "application/json", Schemas.RotateAuditKeyRequest},
    responses: %{
      200 =>
        {"Halt cleared", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      401 => {"WebAuthn required or failed", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/admin/tenants/:id/clear-halt

  Break-glass custody-halt recovery (Chain of Custody v2, L6). Superadmin
  key alone is NOT sufficient: the caller must present a WebAuthn assertion
  verified against a challenge issued by `challenge/2` and the target
  tenant's enrolled root authenticator. The challenge is consumed exactly
  once; replay is rejected.
  """
  def clear_halt(conn, %{"id" => id} = params) do
    # Break-glass requires a VERIFIED WebAuthn assertion, not merely a
    # present one. Mirror the rotate-audit-key guard: the assertion must be
    # a map (the separate base64url fields), then it is cryptographically
    # verified and the single-use challenge consumed before the halt clears.
    assertion = Map.get(params, "webauthn_assertion")

    if is_map(assertion) do
      verify_and_clear_halt(conn, id, assertion)
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{
        error: %{
          code: "webauthn_required",
          status: 401,
          message:
            "Break-glass operations require a WebAuthn assertion from a root authenticator",
          remediation: %{learn_more: "https://loopctl.com/wiki/break-glass"}
        }
      })
    end
  end

  defp verify_and_clear_halt(conn, id, assertion) do
    # Verify the assertion against the STORED challenge and the tenant's
    # enrolled authenticator (challenge binding, signature, counter). The
    # ceremony is single-use: the challenge is consumed here regardless of
    # outcome. Only a genuinely verified assertion reaches do_clear_halt.
    case Reauth.verify_and_consume(id, @clear_halt_purpose, assertion) do
      {:ok, _verified} ->
        do_clear_halt(conn, id)

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: %{
            code: "webauthn_failed",
            status: 401,
            message: "WebAuthn assertion verification failed"
          }
        })
    end
  end

  defp do_clear_halt(conn, id) do
    case Tenants.clear_custody_halt(id) do
      {:ok, tenant} ->
        # Break-glass: audit this critical operation
        api_key = conn.assigns.current_api_key

        Loopctl.AuditChain.append(tenant.id, %{
          action: "halt_cleared",
          actor_lineage: [],
          entity_type: "tenant",
          entity_id: tenant.id,
          payload: %{"cleared_by" => api_key.id}
        })

        json(conn, %{data: %{id: tenant.id, custody_halted_at: nil, status: "halt_cleared"}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: %{message: "Not found", status: 404}})
    end
  end
end
