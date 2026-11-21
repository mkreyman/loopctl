defmodule Loopctl.Repo.Migrations.AddRunnerConfigRefusalIndex do
  @moduledoc """
  Issue #1020: the partial index behind the configuration-refusal memory
  (`Loopctl.Runners.DispatchLedger.config_refused/5`), which `Loopctl.Runners.accepts?/5`
  asks for every connected runner of every unattended pass. No column, constraint or policy
  changes; no backfill and no manual step.

  The same reasoning as `20260919100000`'s `kind_not_supported` index: `runner_dispatches` has
  no age-based retention, and the common answer is NO MATCH, which on the general
  `(tenant_id, runner_id)` index costs a read of every dispatch the runner ever held. PARTIAL on
  the refusal reasons the memory reads, so the index holds a handful of rows. The query names
  those reasons as LITERALS so the planner can prove the predicate (see the note in
  `config_refused/5`).

  Built `CONCURRENTLY` behind the same validity guard as `20260919100000`, for the same reason:
  a plain build blocks every dispatch insert, and an interrupted concurrent build leaves an
  INVALID index that `IF NOT EXISTS` would keep.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "runner_dispatches_config_refusal_idx"

  @shape ~r/ON public\.runner_dispatches USING btree \(tenant_id, runner_id, kind, replied_at\)\s+WHERE .*refused.*branch_not_allowed/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON runner_dispatches (tenant_id, runner_id, kind, replied_at)
    WHERE status = 'refused'
      AND reason IN ('repo_not_allowed', 'branch_not_allowed', 'wall_clock_exceeds_limit',
                     'max_turns_exceeds_limit', 'token_budget_exceeds_limit')
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
