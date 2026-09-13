defmodule Loopctl.Repo.Migrations.AddDeliveryLoopRetentionIndexes do
  use Ecto.Migration

  @moduledoc """
  Issue #803 (design §11): the two indexes `Loopctl.Workers.DeliveryLoopPruneWorker` reads.
  No column, constraint or policy changes; no backfill and no manual step.

  1. `runner_trace_events (tenant_id, inserted_at)` — the retention scan. The table's other
     indexes are the dedup key `(tenant_id, run_id, seq)` and `(runner_dispatch_id)`, and
     neither orders by age, so "this tenant's oldest events past the cutoff" was a sequential
     scan of the highest-volume table in the system, once per batch.
     (`create_runner_trace_events` says retention "is not here yet"; this is where it landed.)

  2. `intake_records (tenant_id, source_id, last_delivery_id)` — the guard that keeps a
     delivery row a live queue entry still names. Without it the NOT EXISTS walks every record
     of the source for every candidate delivery, which is quadratic in exactly the tenant that
     has the most of both.

  `CONCURRENTLY` on both, because a plain `create index` takes a SHARE lock for the whole
  build and blocks every INSERT meanwhile — on `runner_trace_events`, which this migration
  itself calls the highest-volume table here, that is every runner's trace stalling behind a
  DDL. `create_if_not_exists` + explicit `up`/`down`, per `20260827121000` and
  `20260905120200`: plain `create index(concurrently: true)` emits no `IF NOT EXISTS`, so an
  interrupted build leaves an INVALID index and no migration row, and every later deploy trips
  over it.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(trace_age_index())
    create_if_not_exists(record_delivery_index())
  end

  def down do
    drop_if_exists(record_delivery_index())
    drop_if_exists(trace_age_index())
  end

  defp trace_age_index do
    index(:runner_trace_events, [:tenant_id, :inserted_at],
      name: :runner_trace_events_tenant_inserted_at_idx,
      concurrently: true
    )
  end

  defp record_delivery_index do
    index(:intake_records, [:tenant_id, :source_id, :last_delivery_id],
      name: :intake_records_tenant_source_last_delivery_idx,
      concurrently: true
    )
  end
end
