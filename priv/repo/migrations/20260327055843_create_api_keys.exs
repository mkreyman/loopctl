defmodule Loopctl.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :key_hash, :string, null: false
      add :key_prefix, :string, null: false
      add :role, :string, null: false
      add :agent_id, :binary_id
      add :last_used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:tenant_id])
    create index(:api_keys, [:role])

    # Enable RLS with a special policy that allows superadmin keys (tenant_id IS NULL)
    execute(
      "ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE api_keys DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE api_keys FORCE ROW LEVEL SECURITY",
      "SELECT 1"
    )

    execute(
      """
      CREATE POLICY tenant_isolation ON api_keys
        USING (
          tenant_id = current_tenant_id()
          OR tenant_id IS NULL
        )
      """,
      "DROP POLICY IF EXISTS tenant_isolation ON api_keys"
    )
  end
end
