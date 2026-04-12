defmodule Loopctl.Repo.Migrations.CreateAuditSignedTreeHeads do
  use Ecto.Migration

  def change do
    create table(:audit_signed_tree_heads, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :chain_position, :bigint, null: false
      add :merkle_root, :binary, null: false
      add :signed_at, :utc_datetime_usec, null: false
      add :signature, :binary, null: false
    end

    create unique_index(:audit_signed_tree_heads, [:tenant_id, :chain_position])
    create index(:audit_signed_tree_heads, [:tenant_id, :signed_at], using: "btree")

    execute(
      "ALTER TABLE audit_signed_tree_heads ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE audit_signed_tree_heads DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON audit_signed_tree_heads
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON audit_signed_tree_heads"
    )
  end
end
