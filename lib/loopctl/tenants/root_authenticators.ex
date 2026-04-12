defmodule Loopctl.Tenants.RootAuthenticators do
  @moduledoc """
  Context functions for managing `tenant_root_authenticators`.

  Every function takes `tenant_id` as the first argument so callers
  cannot accidentally leak data across tenant boundaries. All queries
  are scoped through `AdminRepo` (the signup ceremony runs before the
  request has a RLS-aware tenant context).
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants.RootAuthenticator

  @doc """
  Lists root authenticators for a tenant, newest first.
  """
  @spec list_by_tenant(Ecto.UUID.t(), keyword()) :: [RootAuthenticator.t()]
  def list_by_tenant(tenant_id, _opts \\ []) when is_binary(tenant_id) do
    from(a in RootAuthenticator,
      where: a.tenant_id == ^tenant_id,
      order_by: [desc: a.inserted_at]
    )
    |> AdminRepo.all()
  end

  @doc """
  Fetches a single authenticator by credential id, scoped to the tenant.
  """
  @spec get_by_credential_id(Ecto.UUID.t(), binary()) ::
          {:ok, RootAuthenticator.t()} | {:error, :not_found}
  def get_by_credential_id(tenant_id, credential_id)
      when is_binary(tenant_id) and is_binary(credential_id) do
    query =
      from a in RootAuthenticator,
        where: a.tenant_id == ^tenant_id and a.credential_id == ^credential_id

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      authenticator -> {:ok, authenticator}
    end
  end

  @doc """
  Counts root authenticators for a tenant.
  """
  @spec count_by_tenant(Ecto.UUID.t()) :: non_neg_integer()
  def count_by_tenant(tenant_id) when is_binary(tenant_id) do
    from(a in RootAuthenticator, where: a.tenant_id == ^tenant_id, select: count(a.id))
    |> AdminRepo.one()
  end

  @doc """
  Inserts a new authenticator row for the given tenant.

  `tenant_id` is applied programmatically — never cast from the attrs.
  """
  @spec create(Ecto.UUID.t(), map()) ::
          {:ok, RootAuthenticator.t()} | {:error, Ecto.Changeset.t()}
  def create(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    %RootAuthenticator{tenant_id: tenant_id}
    |> RootAuthenticator.create_changeset(attrs)
    |> AdminRepo.insert()
  end
end
