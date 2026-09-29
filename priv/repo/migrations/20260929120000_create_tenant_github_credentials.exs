defmodule Loopctl.Repo.Migrations.CreateTenantGithubCredentials do
  @moduledoc """
  #936: a tenant's own GitHub token, which every forge call on that tenant's behalf
  authenticates with (`Loopctl.Forge`). One row per tenant; the token is Cloak ciphertext
  (`Loopctl.Vault.Binary`). RLS enabled like every tenant table, and the context filters by
  `tenant_id` explicitly as well because it reads from Oban workers on AdminRepo.
  """
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:tenant_github_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :token, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_github_credentials, [:tenant_id])

    enable_rls(:tenant_github_credentials)
  end
end
