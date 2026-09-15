defmodule Loopctl.Repo.Migrations.AddIntakePendingTriageIndex do
  @moduledoc """
  Issue #803: the partial index behind `Loopctl.Workers.TriageTriggerWorker.candidates/0`. No
  column, constraint or policy changes; no backfill and no manual step.

  That read runs every minute, FLEET-WIDE, and is the one query in the delivery loop with no
  tenant in its predicate: `status = 'pending_triage' ORDER BY inserted_at, id LIMIT 50`. The
  only index on `intake_records` is `(tenant_id, status)`, which is tenant-LEADING and so
  cannot serve it — with no tenant to seek on, the planner sorts the whole table to find the
  fifty oldest. Every delivery ever received is read, once a minute, for ever.

  The candidate set is also the one set in this schema that does not shrink on its own. A
  record leaves it by growing a stage row or by being escalated; a source that names no target
  epic escalates nothing — the worker retries it deliberately, see its `disposition/1` — so
  those records stay `pending_triage` until an operator repoints the source with
  `PATCH /api/v1/intake/sources/:id`. Retried records are exactly the ones an unindexed sort
  re-reads every minute.

  PARTIAL on the status, keyed by the sort, so the scan is bounded by the records actually
  waiting rather than by every record ever received, and the `LIMIT` stops after fifty index
  entries with no sort at all. The index holds only rows in a transient state, so it stays
  small in a healthy tenant and grows only while work is genuinely waiting — which is the
  case it has to be fast in.

  `CONCURRENTLY` plus the validity guard, for the reasons `20260919100000` states: a plain
  build blocks every webhook delivery for its duration, and an interrupted concurrent build
  leaves an INVALID index occupying the name, which `IF NOT EXISTS` would decline to replace
  while no planner would use it — the scan would silently come back. `stale?/2` reconciles
  validity and SHAPE rather than the name. Absent is not stale.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "intake_records_pending_triage_idx"

  # Loose on parenthesisation and casts (both deparser-version dependent), exact on the table
  # and the key order, and it MUST be partial on the status: a full index of the same columns
  # would answer the query while holding every record ever received, which is the cost this
  # migration exists to avoid.
  @shape ~r/ON public\.intake_records USING btree \(inserted_at, id\)\s+WHERE .*pending_triage/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON intake_records (inserted_at, id)
    WHERE status = 'pending_triage'
  """

  def up do
    if stale?(@name, @shape), do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")
    execute(@create)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")
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
