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

  alias Loopctl.Audit
  alias Loopctl.Tenants

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, exact_role: :superadmin

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
      api_key = conn.assigns.current_api_key

      case Tenants.update_tenant_admin(tenant, params) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_updated",
            actor_type: "superadmin",
            actor_id: api_key.id,
            actor_label: "superadmin:#{api_key.name}",
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
      api_key = conn.assigns.current_api_key

      case Tenants.suspend_tenant(tenant) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_suspended",
            actor_type: "superadmin",
            actor_id: api_key.id,
            actor_label: "superadmin:#{api_key.name}",
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
      api_key = conn.assigns.current_api_key

      case Tenants.activate_tenant(tenant) do
        {:ok, updated} ->
          Audit.create_log_entry(updated.id, %{
            entity_type: "tenant",
            entity_id: updated.id,
            action: "tenant_activated",
            actor_type: "superadmin",
            actor_id: api_key.id,
            actor_label: "superadmin:#{api_key.name}",
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
end
