defmodule LoopctlWeb.TenantController do
  @moduledoc """
  Controller for tenant registration and tenant profile management.

  - `POST /api/v1/tenants/register` — public, creates tenant + first API key
  - `GET /api/v1/tenants/me` — authenticated, returns current tenant profile
  - `PATCH /api/v1/tenants/me` — authenticated, updates current tenant
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  # Agents and orchestrators can view tenant profile but only users+ can modify settings
  plug LoopctlWeb.Plugs.RequireRole, [role: :user] when action in [:update]

  tags(["Tenants"])

  operation(:register,
    summary: "Register a new tenant",
    description:
      "Public endpoint. Creates a new tenant and first user-role API key. " <>
        "The raw API key is returned only once.",
    security: [],
    request_body: {"Registration params", "application/json", Schemas.TenantRegistrationRequest},
    responses: %{
      201 => {"Tenant created", "application/json", Schemas.TenantRegistrationResponse},
      409 => {"Conflict", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:show,
    summary: "Get current tenant profile",
    description: "Returns the tenant profile for the authenticated API key.",
    responses: %{
      200 => {"Tenant profile", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse}
    }
  )

  operation(:update,
    summary: "Update current tenant profile",
    description: "Updates the tenant profile. Requires user+ role.",
    request_body: {"Update params", "application/json", Schemas.TenantResponse},
    responses: %{
      200 => {"Updated tenant", "application/json", Schemas.TenantResponse},
      401 => {"Unauthorized", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse}
    }
  )

  @doc """
  POST /api/v1/tenants/register

  Public endpoint. Creates a new tenant and first user-role API key.
  Returns the raw API key once.
  """
  def register(conn, params) do
    case Auth.register_tenant(params) do
      {:ok, %{tenant: tenant, raw_key: raw_key, api_key: api_key}} ->
        conn
        |> put_status(:created)
        |> json(%{
          tenant: tenant_json(tenant),
          api_key: %{
            id: api_key.id,
            raw_key: raw_key,
            key_prefix: api_key.key_prefix,
            role: api_key.role,
            name: api_key.name
          }
        })

      {:error, :conflict} ->
        {:error, :conflict}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

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
