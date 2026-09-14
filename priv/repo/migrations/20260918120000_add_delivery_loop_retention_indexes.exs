defmodule Loopctl.Repo.Migrations.AddDeliveryLoopRetentionIndexes do
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

  ## Why CONCURRENTLY, and why that needs a validity guard

  A plain build takes a SHARE lock for its whole duration and blocks every INSERT meanwhile —
  on `runner_trace_events` that is every runner's trace stalling behind DDL. So both are built
  `CONCURRENTLY`, which costs `@disable_ddl_transaction` + `@disable_migration_lock` and raw
  `execute/1`.

  The guard is the other half and it is NOT optional. An interrupted concurrent build leaves
  an INVALID index behind: it still occupies the name, so `IF NOT EXISTS` quietly declines to
  build a working one, and no planner will use it. On this table that means the retention scan
  silently goes back to a sequential scan of the largest table here — a pruner that looks like
  it is running and is not. `stale?/1` therefore reconciles VALIDITY and SHAPE, not just the
  name, and drops what it finds before the create; this is the `ensure_index` pattern from
  `20260821120000` / `20260825130000` / `20260827121000`. Absent is not stale — there is
  nothing to drop and the create lays it down.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @trace_name "runner_trace_events_tenant_inserted_at_idx"
  @record_name "intake_records_tenant_source_last_delivery_idx"

  # Loose on the deparser's parenthesisation and casts (both version dependent), exact on the
  # table and the key order — the two things that decide whether the retention scan uses it.
  @trace_shape ~r/ON public\.runner_trace_events USING btree \(tenant_id, inserted_at\)/
  @record_shape ~r/ON public\.intake_records USING btree \(tenant_id, source_id, last_delivery_id\)/

  @create_trace """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@trace_name}
    ON runner_trace_events (tenant_id, inserted_at)
  """

  @create_record """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@record_name}
    ON intake_records (tenant_id, source_id, last_delivery_id)
  """

  def up do
    if stale?(@trace_name, @trace_shape),
      do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@trace_name}")

    execute(@create_trace)

    if stale?(@record_name, @record_shape),
      do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@record_name}")

    execute(@create_record)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@record_name}")
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@trace_name}")
  end

  # Stale = INVALID, a different shape, or ambiguous. Absent is NOT stale.
  defp stale?(name, shape) do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid
      FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case repo().query!(sql, [name]).rows do
      [[indexdef, true]] -> not (indexdef =~ shape)
      rows -> rows != []
    end
  end
end
