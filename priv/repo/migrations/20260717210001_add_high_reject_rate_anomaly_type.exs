defmodule Loopctl.Repo.Migrations.AddHighRejectRateAnomalyType do
  use Ecto.Migration

  @moduledoc """
  Widens the `ingestion_anomalies.anomaly_type` CHECK constraint to admit the new
  `:high_reject_rate` detector value (the no-persist / high-rejection-rate sibling
  of `capture_silence`).

  The original CHECK (from `CreateIngestionAnomalies`) only allowed
  `('capture_silence')`; inserting a `high_reject_rate` row would fail the CHECK.
  Drop and recreate it with both values. Reversible: the `down` restores the
  single-value CHECK.
  """

  def up do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate'))"
    )
  end

  def down do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence'))"
    )
  end
end
