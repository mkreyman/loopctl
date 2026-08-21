defmodule Loopctl.Repo.Migrations.WidenPotentialConflictPartialIndexForAssertions do
  @moduledoc """
  Widen `article_links_potential_conflict_idx` to cover ASSERTED conflict flags (#730).

  `Knowledge.list_potential_conflicts/2` now selects on
  `auto_generated = 'true' OR asserted = 'true'`, while the index laid down by
  20260804220000 is partial on `auto_generated` ALONE. A partial index is only usable when
  its predicate is implied by the query's, and `A OR B` does not imply `A` — so the
  conflict queue silently stopped using it and went back to the seq scan + sort that
  migration measured at 313 ms against the index's 0.131 ms.

  The predicate is widened rather than a sibling index added: one index keeps the
  `(tenant_id, similarity DESC, id)` ordering intact for the combined result set, which is
  what the queue's single `ORDER BY` needs. Two partial indexes would each cover half of an
  OR and the planner would have to merge and re-sort them.

  ASSERTED rows carry NO `similarity_score`, so the indexed `::float` cast sees NULL on
  them — fine, and it is why the `DESC` (NULLS FIRST) key order is unchanged: assertions
  sort first, which is exactly the order the queue asks for. The cast being a write-path
  invariant still holds — a row matching this predicate with a NON-NUMERIC
  `similarity_score` would fail its write — and the widened predicate now brings asserted
  rows under it. `Knowledge.assert_conflict/3` never writes that key, and the promoter's
  upgrade writes a real float.

  Same `ensure_index/2` guard as 20260804220000: CONCURRENTLY, and DROP only a mismatched
  or INVALID catalog entry, so a prod out-of-band build or a retry keeps its live index.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "article_links_potential_conflict_idx"

  # Loose on the deparser's parenthesisation (version dependent), exact on key order and on
  # BOTH predicate arms — a catalog still carrying the auto_generated-only predicate must
  # read as stale and be rebuilt.
  @shape ~r/USING btree \(tenant_id, .*similarity_score.*DESC, id\) WHERE .*auto_generated.*asserted/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS article_links_potential_conflict_idx
    ON article_links (tenant_id, ((metadata->>'similarity_score')::float) DESC, id)
    WHERE relationship_type = 'potential_conflict'
      AND ((metadata->>'auto_generated') = 'true' OR (metadata->>'asserted') = 'true')
  """

  @previous """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS article_links_potential_conflict_idx
    ON article_links (tenant_id, ((metadata->>'similarity_score')::float) DESC, id)
    WHERE relationship_type = 'potential_conflict'
      AND (metadata->>'auto_generated') = 'true'
  """

  def up, do: ensure_index(@shape, @create)

  def down,
    do:
      ensure_index(
        ~r/USING btree \(tenant_id, .*similarity_score.*DESC, id\) WHERE .*auto_generated/,
        @previous
      )

  defp ensure_index(shape, create_sql) do
    if stale?(shape), do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")
    execute(create_sql)
  end

  # Stale = INVALID, a different shape, or ambiguous. Absent is NOT stale: nothing to drop,
  # and the CREATE below lays it down.
  defp stale?(shape) do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid
      FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case repo().query!(sql, [@name]).rows do
      [[indexdef, true]] -> not (indexdef =~ shape)
      rows -> rows != []
    end
  end
end
