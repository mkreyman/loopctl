defmodule Loopctl.Repo.Migrations.CreateIngestionAnomalies do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:ingestion_anomalies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      # WHAT went silent: the article `source_type` (e.g. "session_log") whose
      # captured-write stream stopped, and WHY it was flagged.
      add :source_type, :string, null: false
      add :anomaly_type, :string, null: false

      # The freshness snapshot at detection time.
      add :last_event_at, :utc_datetime_usec
      add :hours_stale, :integer, null: false
      add :sample_count, :integer, null: false

      add :resolved, :boolean, default: false, null: false
      # Mirror cost_anomalies: archived rows are excluded from the default list.
      add :archived, :boolean, default: false, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # anomaly_type CHECK constraint (extensible list — mirrors cost_anomalies).
    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check CHECK (anomaly_type IN ('capture_silence'))",
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    # Lookup indexes for common queries.
    create index(:ingestion_anomalies, [:tenant_id])
    create index(:ingestion_anomalies, [:tenant_id, :resolved])
    create index(:ingestion_anomalies, [:tenant_id, :source_type])

    # Race-safe create: ONE unresolved anomaly per (tenant, source_type, anomaly_type).
    # `insert_all` + `on_conflict: :nothing` targets this exact partial index so a
    # concurrent detector run reports 0 rows written (skip notify) instead of
    # duplicating. Mirrors :cost_anomalies_unresolved_unique exactly.
    create unique_index(:ingestion_anomalies, [:tenant_id, :source_type, :anomaly_type],
             where: "resolved = false",
             name: :ingestion_anomalies_unresolved_unique
           )

    enable_rls(:ingestion_anomalies)
  end
end
