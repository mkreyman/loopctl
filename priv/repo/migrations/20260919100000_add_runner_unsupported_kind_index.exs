defmodule Loopctl.Repo.Migrations.AddRunnerUnsupportedKindIndex do
  @moduledoc """
  Issue #803, contract 1.5.0: the partial index behind the `kind_not_supported` capability
  memory. No column, constraint or policy changes; no backfill and no manual step.

  `Loopctl.Runners.DispatchLedger.kind_unsupported?/3` runs on the DISPATCH HOT PATH and
  `unsupported_kinds/1` on every `GET /api/v1/runners` and `GET /api/v1/runners/pool`. Both
  answer from `runner_dispatches`, whose only usable index was `(tenant_id, runner_id)` — and
  the table has no age-based retention, so it only grows. The COMMON case is the worst one:
  with no matching row, `exists?` has to examine every dispatch that runner ever held to
  answer false, and the pool read scans the tenant's whole history. A tenant six months in
  pays that per dispatch and per pool poll.

  PARTIAL on the two columns the predicate fixes, so the index holds only the refusals that
  are capability statements — a handful of rows in the life of a tenant, and usually none.
  Both reads then cost a lookup proportional to the MATCHES rather than to the history.

  ## Why CONCURRENTLY, and why that needs a validity guard

  A plain build takes a SHARE lock for its whole duration and blocks every INSERT meanwhile;
  on this table that is every dispatch and every reply stalling behind DDL. So it is built
  `CONCURRENTLY`, which costs `@disable_ddl_transaction` + `@disable_migration_lock` and raw
  `execute/1`.

  The guard is the other half. An interrupted concurrent build leaves an INVALID index that
  still occupies the name, so `IF NOT EXISTS` quietly declines to build a working one and no
  planner will use it — the dispatch path would silently go back to the scan this migration
  exists to remove, looking healthy the whole time. `stale?/2` reconciles VALIDITY and SHAPE
  rather than the name, and drops what it finds before the create; this is the `ensure_index`
  pattern from `20260918120000` and its predecessors. Absent is not stale.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "runner_dispatches_unsupported_kind_idx"

  # Loose on the deparser's parenthesisation and casts (both version dependent), exact on the
  # table and the key order, and it must be PARTIAL on both predicate values — a full index of
  # the same columns would answer the query and hold every row in the table, which is the cost
  # this migration exists to avoid.
  @shape ~r/ON public\.runner_dispatches USING btree \(tenant_id, runner_id, kind\)\s+WHERE .*refused.*kind_not_supported/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@name}
    ON runner_dispatches (tenant_id, runner_id, kind)
    WHERE status = 'refused' AND reason = 'kind_not_supported'
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
