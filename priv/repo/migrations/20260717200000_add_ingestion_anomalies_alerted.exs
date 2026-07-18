defmodule Loopctl.Repo.Migrations.AddIngestionAnomaliesAlerted do
  use Ecto.Migration

  @moduledoc """
  Adds `alerted` to `ingestion_anomalies` to make operator-alert + webhook
  notification AT-LEAST-ONCE across worker crashes/retries.

  The anomaly row + its `detected` audit entry are inserted atomically, but the
  operator alert and webhook enqueues run POST-commit. If the worker crashed
  between commit and enqueue, the Oban retry would find the now-committed
  unresolved row and take the no-notify update path — silently losing the alert
  for a genuine capture-silence event across all retries. `alerted` records
  whether the out-of-band notifications were successfully fired, so a later run
  that sees an unresolved-but-unalerted row re-fires them (idempotent recovery).
  """

  def change do
    alter table(:ingestion_anomalies) do
      add :alerted, :boolean, default: false, null: false
    end
  end
end
