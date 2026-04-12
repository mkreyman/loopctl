defmodule Loopctl.Repo.Migrations.AddAuditSigningKeyToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :audit_signing_public_key, :binary
      add :audit_key_rotated_at, :utc_datetime_usec
    end

    create table(:tenant_audit_key_history, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :public_key, :binary, null: false
      add :rotated_in, :utc_datetime_usec, null: false
      add :rotated_out, :utc_datetime_usec
      add :rotation_signature, :binary

      timestamps()
    end

    create index(:tenant_audit_key_history, [:tenant_id])

    execute(
      "ALTER TABLE tenant_audit_key_history ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE tenant_audit_key_history DISABLE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_policy ON tenant_audit_key_history
        USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid)
      """,
      "DROP POLICY IF EXISTS tenant_isolation_policy ON tenant_audit_key_history"
    )
  end
end
