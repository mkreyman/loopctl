defmodule Loopctl.Repo.Migrations.AddDeliveryLoopRetentionIndexes do
  use Ecto.Migration

  # Issue #803 (design §11): the two indexes `Loopctl.Workers.DeliveryLoopPruneWorker` reads.
  # No column, constraint or policy changes; no backfill and no manual step.
  #
  # 1. `runner_trace_events (tenant_id, inserted_at)` — the retention scan. The table's other
  #    indexes are the dedup key `(tenant_id, run_id, seq)` and `(runner_dispatch_id)`, and
  #    neither orders by age, so "this tenant's oldest events past the cutoff" was a
  #    sequential scan of the highest-volume table in the system, once per batch.
  #    (`create_runner_trace_events` says retention "is not here yet"; this is where it
  #    landed.)
  #
  # 2. `intake_records (tenant_id, source_id, last_delivery_id)` — the guard that keeps a
  #    delivery row a live queue entry still names. Without it the NOT EXISTS walks every
  #    record of the source for every candidate delivery, which is quadratic in exactly the
  #    tenant that has the most of both.
  def change do
    create index(:runner_trace_events, [:tenant_id, :inserted_at])
    create index(:intake_records, [:tenant_id, :source_id, :last_delivery_id])
  end
end
