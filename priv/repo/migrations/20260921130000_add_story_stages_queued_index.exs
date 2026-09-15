defmodule Loopctl.Repo.Migrations.AddStoryStagesQueuedIndex do
  @moduledoc """
  Issue #803: the partial index behind `Loopctl.Delivery.DispatchDriver.candidates/1`. No
  column, constraint or policy changes; no backfill and no manual step.

  The driver's candidate read is fleet-wide with no tenant in its predicate —
  `stage = 'queued' ORDER BY updated_at, story_id LIMIT n` — and runs every pass. It is the
  same shape as the triage trigger's, and migration `20260921110000` records what that cost
  before it had an index: the only index on the table is tenant-leading, so with no tenant to
  seek on the planner sorts every stage row ever written to find the oldest few.

  PARTIAL on the status, keyed by the sort. `queued` is a TRANSIENT stage — a story leaves it
  the moment it is claimed — so the index holds only work actually waiting, which keeps it
  small in a healthy fleet and large exactly when the driver most needs it to be fast.

  `CONCURRENTLY` plus the validity guard, for the reasons `20260919100000` states: a plain
  build blocks every stage transition for its duration, and an interrupted concurrent build
  leaves an INVALID index occupying the name, which `IF NOT EXISTS` would decline to replace
  while no planner would use it — the scan would silently come back. `stale?/2` reconciles
  validity and SHAPE rather than the name. Absent is not stale.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "story_stages_queued_idx"

  # Loose on parenthesisation and casts (deparser-version dependent), exact on the table and
  # key order, and it MUST be partial on the stage: a full index of the same columns would
  # answer the query while holding every stage row in the fleet.
  @shape ~r/ON public\.story_stages USING btree \(updated_at, story_id\)\s+WHERE .*queued/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON story_stages (updated_at, story_id)
    WHERE stage = 'queued'
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
