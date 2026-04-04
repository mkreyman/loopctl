defmodule Loopctl.Repo.Migrations.AddTokenDataRetentionAndAnomalyArchive do
  use Ecto.Migration

  def change do
    # AC-21.14.1: Add token_data_retention_days to tenants.
    # NULL means unlimited retention (no archival).
    alter table(:tenants) do
      add :token_data_retention_days, :integer, null: true
    end

    # AC-21.14.5: Add archived flag to cost_anomalies.
    # Archived anomalies are excluded from the default list.
    alter table(:cost_anomalies) do
      add :archived, :boolean, null: false, default: false
    end

    # Index for efficient hard-delete pass: WHERE deleted_at IS NOT NULL
    execute(
      "CREATE INDEX token_usage_reports_deleted_at_idx ON token_usage_reports (tenant_id, deleted_at) WHERE deleted_at IS NOT NULL",
      "DROP INDEX IF EXISTS token_usage_reports_deleted_at_idx"
    )

    # Index for anomaly archival queries
    create index(:cost_anomalies, [:tenant_id, :archived])
  end
end
