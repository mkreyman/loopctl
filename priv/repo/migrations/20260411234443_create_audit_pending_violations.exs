defmodule Loopctl.Repo.Migrations.CreateAuditPendingViolations do
  use Ecto.Migration

  def change do
    create table(:audit_pending_violations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing)
      add :violation_type, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :binary_id
      add :discovered_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :detail, :map, null: false, default: "{}"
      add :status, :string, null: false, default: "pending"
      add :resolved_at, :utc_datetime_usec
      add :resolved_by_api_key_id, :binary_id
      add :resolution_note, :text

      timestamps()
    end

    create index(:audit_pending_violations, [:tenant_id])
    create index(:audit_pending_violations, [:violation_type])
    create index(:audit_pending_violations, [:status])
  end
end
