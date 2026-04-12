defmodule Loopctl.Repo.Migrations.CreateDispatches do
  use Ecto.Migration

  def change do
    create table(:dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :parent_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nothing)
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nothing)
      add :story_id, references(:stories, type: :binary_id, on_delete: :nothing)
      add :role, :string, null: false
      add :lineage_path, {:array, :binary_id}, null: false, default: "{}"
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # GIN index for lineage_path containment queries
    execute(
      "CREATE INDEX dispatches_lineage_path_idx ON dispatches USING GIN (lineage_path)",
      "DROP INDEX IF EXISTS dispatches_lineage_path_idx"
    )

    # Active dispatch queries
    create index(:dispatches, [:tenant_id, :expires_at])
    create index(:dispatches, [:tenant_id, :role])

    # RLS
    execute(
      "ALTER TABLE dispatches ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE dispatches DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON dispatches
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON dispatches"
    )
  end
end
