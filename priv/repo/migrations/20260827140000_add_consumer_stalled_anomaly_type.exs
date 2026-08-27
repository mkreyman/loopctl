defmodule Loopctl.Repo.Migrations.AddConsumerStalledAnomalyType do
  use Ecto.Migration

  @moduledoc """
  Widens the `ingestion_anomalies.anomaly_type` CHECK constraint to admit the new
  `:consumer_stalled` detector value (#765 item 6): the nightly knowledge-lint
  consumers (draft publishing, duplicate unpublishing, generic-title retitling,
  conflict judging) completed run after run while disposing of NOTHING, or the
  nightly pass stopped completing altogether.

  Same shape as `AddSecretDetectedAnomalyType`: drop and recreate the CHECK with the
  widened value set. Reversible — the `down` first removes any persisted
  `consumer_stalled` rows (which the narrowed CHECK would reject, failing the ADD
  CONSTRAINT) and then restores the previous four-value CHECK.
  """

  def up do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled', " <>
        "'secret_detected', 'consumer_stalled'))"
    )
  end

  def down do
    execute(
      "ALTER TABLE ingestion_anomalies DROP CONSTRAINT ingestion_anomalies_anomaly_type_check"
    )

    execute("DELETE FROM ingestion_anomalies WHERE anomaly_type = 'consumer_stalled'")

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled', " <>
        "'secret_detected'))"
    )
  end
end
