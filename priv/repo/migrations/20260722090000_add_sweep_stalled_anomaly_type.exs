defmodule Loopctl.Repo.Migrations.AddSweepStalledAnomalyType do
  use Ecto.Migration

  @moduledoc """
  Widens the `ingestion_anomalies.anomaly_type` CHECK constraint to admit the new
  `:sweep_stalled` detector value (issue #498): a tenant whose expired
  `channel_posts` are still present long after `expires_at`, i.e. the US-39.5
  30-day retention sweep is no longer being enforced for that tenant.

  Same shape as `AddHighRejectRateAnomalyType`: drop and recreate the CHECK with the
  widened value set. Reversible — the `down` first removes any persisted
  `sweep_stalled` rows (which the narrowed CHECK would reject, failing the ADD
  CONSTRAINT) and then restores the previous two-value CHECK.
  """

  def up do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled'))"
    )
  end

  def down do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    # Remove rows the narrowed CHECK can no longer admit — otherwise ADD CONSTRAINT
    # raises on the existing sweep_stalled rows and the rollback fails.
    execute("DELETE FROM ingestion_anomalies WHERE anomaly_type = 'sweep_stalled'")

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate'))"
    )
  end
end
