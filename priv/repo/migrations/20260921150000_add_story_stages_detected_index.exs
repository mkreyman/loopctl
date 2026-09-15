defmodule Loopctl.Repo.Migrations.AddStoryStagesDetectedIndex do
  @moduledoc """
  Issue #803: the partial index behind `Loopctl.Delivery.TriageDispatcher.candidates/1`. No
  column, constraint or policy changes; no backfill and no manual step.

  The SAME shape, for the same reason, as `20260921130000`'s `queued` index — that migration
  carries the full argument and this one does not repeat it. The triage pass ranks each
  tenant's detected queue separately (`row_number() OVER (PARTITION BY tenant_id ORDER BY
  updated_at, story_id)`), runs every minute, and runs on the three-connection `AdminRepo`
  pool every authenticated request shares, so an unindexed sort of the whole `story_stages`
  table is felt by the API and not only by the worker. The only other index on the table is
  tenant-leading with the stage nowhere in it.

  `detected` differs from `queued` in ONE way that matters to the planner, and it argues for
  the partial index rather than against it: a story stays at `detected` until its verdict
  comes back, so in a fleet whose runners do not declare `triage` this set GROWS without
  bound. That is exactly when the sort is most expensive and the index most worth having.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "story_stages_detected_idx"

  @shape ~r/ON public\.story_stages USING btree \(tenant_id, updated_at, story_id\)\s+WHERE .*detected/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON story_stages (tenant_id, updated_at, story_id)
    WHERE stage = 'detected'
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
