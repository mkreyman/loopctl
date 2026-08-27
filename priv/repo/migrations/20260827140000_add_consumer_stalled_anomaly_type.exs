defmodule Loopctl.Repo.Migrations.AddConsumerStalledAnomalyType do
  use Ecto.Migration

  @moduledoc """
  Widens the `ingestion_anomalies.anomaly_type` CHECK constraint to admit the new
  `:consumer_stalled` detector value (#765 item 6): the nightly knowledge-lint
  consumers (draft publishing, duplicate unpublishing, generic-title retitling, conflict judging)
  completed run after run while disposing of NOTHING, or the pass stopped completing altogether.

  Same shape as `AddSecretDetectedAnomalyType`: drop and recreate the CHECK with the widened value
  set. Reversible, and non-destructive in that direction — the `down` RETAGS any persisted
  `consumer_stalled` row (which the narrowed CHECK would reject, failing the ADD CONSTRAINT)
  instead of deleting it, because the append-only `audit_log` holds `detected` entries whose
  `entity_id` points at those rows and a DELETE strands them. The retag is to a value the
  narrowed CHECK admits, so the row is also RESOLVED and ARCHIVED: `capture_silence` under a
  `knowledge_lint_*` source_type is not a capture stream, and leaving it listable would show
  the operator a mis-typed anomaly the rolled-back code cannot explain. `rolled_back_from`
  records what it really was.
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

    # A value the narrowed CHECK admits; resolved AND archived so neither the rolled-back
    # code nor the default anomaly list surfaces a capture_silence row for a consumer.
    execute("""
    UPDATE ingestion_anomalies
       SET anomaly_type = 'capture_silence',
           resolved = true,
           archived = true,
           metadata = COALESCE(metadata, '{}'::jsonb) ||
                      '{"rolled_back_from": "consumer_stalled"}'::jsonb
     WHERE anomaly_type = 'consumer_stalled'
    """)

    execute(
      "ALTER TABLE ingestion_anomalies ADD CONSTRAINT ingestion_anomalies_anomaly_type_check " <>
        "CHECK (anomaly_type IN ('capture_silence', 'high_reject_rate', 'sweep_stalled', " <>
        "'secret_detected'))"
    )
  end
end
