defmodule LoopctlWeb.TenantController do
  @moduledoc """
  Controller for tenant profile management.

  - `GET /api/v1/tenants/me` — authenticated, returns current tenant profile
  - `PATCH /api/v1/tenants/me` — authenticated, updates current tenant

  Prior to Chain of Custody v2 (US-26.0.1) this controller also hosted
  `POST /api/v1/tenants/register`. That endpoint is removed —
  `/signup` (the WebAuthn-gated LiveView) is now the only path to
  create a tenant.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  # Agents and orchestrators can view tenant profile but only users+ can modify settings
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:update]

  tags(["Tenants"])

  operation(:show,
    summary: "Get current tenant profile",
    description: "Returns the tenant profile for the authenticated API key.",
    responses: %{
      200 => {"Tenant profile", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:update,
    summary: "Update current tenant profile",
    description: "Updates the tenant profile. Requires user+ role.",
    request_body: {"Update params", "application/json", Schemas.TenantResponse},
    responses: %{
      200 => {"Updated tenant", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc """
  GET /api/v1/tenants/me

  Returns the current tenant profile based on the authenticated API key.
  """
  def show(conn, _params) do
    with {:ok, tenant} <- require_tenant(conn) do
      conn
      |> put_status(:ok)
      |> json(%{tenant: tenant_json(tenant)})
    end
  end

  @doc """
  PATCH /api/v1/tenants/me

  Updates the current tenant profile.
  """
  def update(conn, params) do
    with {:ok, tenant} <- require_tenant(conn) do
      case Tenants.update_tenant(tenant, params) do
        {:ok, updated} ->
          conn
          |> put_status(:ok)
          |> json(%{tenant: tenant_json(updated)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp tenant_json(tenant) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      email: tenant.email,
      settings: tenant.settings,
      status: tenant.status,
      token_data_retention_days: tenant.token_data_retention_days,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }
  end

  defp require_tenant(conn) do
    case conn.assigns[:current_tenant] do
      %{id: _} = tenant -> {:ok, tenant}
      _ -> {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}
    end
  end
end
