defmodule Loopctl.Repo.Migrations.AddStoryStagesVerifiedIndex do
  @moduledoc """
  Issue #803: the partial index behind `Loopctl.Delivery.Completion.candidates/1`. No column,
  constraint or policy changes; no backfill and no manual step.

  The THIRD fleet-wide `row_number() OVER (PARTITION BY tenant_id ORDER BY updated_at,
  story_id)` read over `story_stages`, and the SAME shape and reasoning as `20260921130000`
  (`queued`) and `20260921150000` (`detected`) — those two carry the full argument and this one
  does not repeat it. Keyed `(tenant_id, updated_at, story_id)` because that is the window's
  own PARTITION BY plus its ORDER BY, partial on the stage so it holds only the rows the sweep
  reads, and `CONCURRENTLY` with the same validity guard.

  `verified` differs from both siblings in the way that argues hardest FOR the index: it is not
  a transient stage that a story leaves in minutes. A story rests there for as long as its
  issue-closure obligation is outstanding, and NOTHING PRUNES `story_stages` at all — the
  delivery-loop retention pass covers `runner_trace_events` and `intake_deliveries` and not
  this table — so without the index the planner sorts every stage row ever written, every
  minute, on the three-connection AdminRepo pool that every authenticated request shares.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "story_stages_verified_idx"

  # Loose on parenthesisation and casts (deparser-version dependent), exact on the table and
  # key ORDER — `(tenant_id, updated_at, story_id)` is the window's partition plus its sort,
  # and any other order makes the planner sort again — and it MUST be partial on the stage: a
  # full index of the same columns would answer the query while holding every stage row in the
  # fleet.
  @shape ~r/ON public\.story_stages USING btree \(tenant_id, updated_at, story_id\)\s+WHERE .*verified/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON story_stages (tenant_id, updated_at, story_id)
    WHERE stage = 'verified'
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
