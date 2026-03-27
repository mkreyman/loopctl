defmodule Loopctl.Tenants do
  @moduledoc """
  Context module for tenant management.

  Tenants are the root organizational unit. They are NOT tenant-scoped
  (no RLS) because the tenants table is queried by the auth pipeline
  before tenant context is set.

  All queries use `AdminRepo` since tenants have no `tenant_id`
  and are not subject to RLS policies.
  """

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.Tenant

  @doc """
  Creates a new tenant with the given attributes.

  ## Examples

      iex> create_tenant(%{name: "Acme", slug: "acme", email: "a@acme.com"})
      {:ok, %Tenant{}}

      iex> create_tenant(%{name: "Acme"})
      {:error, %Ecto.Changeset{}}
  """
  @spec create_tenant(map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  Gets a tenant by ID.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant(Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant(id) do
    case AdminRepo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Gets a tenant by slug.

  Returns `{:ok, tenant}` or `{:error, :not_found}`.
  """
  @spec get_tenant_by_slug(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) do
    case AdminRepo.get_by(Tenant, slug: slug) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc """
  Updates a tenant with the given attributes.
  """
  @spec update_tenant(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs) do
    tenant
    |> Tenant.update_changeset(attrs)
    |> AdminRepo.update()
  end

  @doc """
  Lists all tenants. Intended for superadmin use.

  Accepts optional filters:
  - `:status` — filter by tenant status
  """
  @spec list_tenants(keyword()) :: {:ok, [Tenant.t()]}
  def list_tenants(opts \\ []) do
    import Ecto.Query

    query =
      Tenant
      |> apply_status_filter(opts[:status])
      |> order_by([t], asc: t.name)

    {:ok, AdminRepo.all(query)}
  end

  @doc """
  Suspends a tenant by setting its status to `:suspended`.
  """
  @spec suspend_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def suspend_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:suspended)
    |> AdminRepo.update()
  end

  @doc """
  Activates a tenant by setting its status to `:active`.
  """
  @spec activate_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def activate_tenant(%Tenant{} = tenant) do
    tenant
    |> Tenant.status_changeset(:active)
    |> AdminRepo.update()
  end

  @doc """
  Gets a specific setting value from a tenant's settings map.

  Falls back to `default` if the key is not present.

  ## Examples

      iex> get_tenant_settings(tenant, "max_projects", 50)
      10  # if tenant.settings has "max_projects" => 10

      iex> get_tenant_settings(tenant, "nonexistent", 42)
      42  # fallback default
  """
  @spec get_tenant_settings(Tenant.t(), String.t(), term()) :: term()
  def get_tenant_settings(%Tenant{settings: settings}, key, default \\ nil) do
    Map.get(settings || %{}, key, default)
  end

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, status) do
    import Ecto.Query
    where(query, [t], t.status == ^status)
  end
end
