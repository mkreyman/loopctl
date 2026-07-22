defmodule Loopctl.Repo.Migrations.AddSecretDetectedAnomalyType do
  use Ecto.Migration

  @moduledoc """
  Widens the `ingestion_anomalies.anomaly_type` CHECK constraint to admit the new
  `:secret_detected` detector value (issue #499): the US-39.1 denylist rescan
  (`Loopctl.Workers.ChannelPostRescanWorker`) quarantined at least one live
  `channel_posts` row that carries a credential shape the write-time gate missed.

  Same shape as `AddSweepStalledAnomalyType`: drop and recreate the CHECK with the
  widened value set. Reversible — the `down` first removes any persisted
  `secret_detected` rows (which the narrowed CHECK would reject, failing the ADD
  CONSTRAINT) and then restores the previous three-value CHECK.
  """

  def up do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled', " <>
        "'secret_detected'))"
    )
  end

  def down do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute("DELETE FROM ingestion_anomalies WHERE anomaly_type = 'secret_detected'")

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled'))"
    )
  end
end
