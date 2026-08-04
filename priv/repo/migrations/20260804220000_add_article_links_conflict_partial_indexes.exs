defmodule Loopctl.Repo.Migrations.AddArticleLinksConflictPartialIndexes do
  @moduledoc """
  Two partial indexes on `article_links` for the conflict/contradiction reads (#576, #577).

  Both reads filter on `relationship_type`, which is the LAST column of
  `article_links_tenant_src_tgt_rel_index (tenant_id, source_article_id, target_article_id,
  relationship_type)` with two unbounded columns before it. Only PostgreSQL 18's btree skip
  scan kept them off a sequential scan at all — verified by forcing `plan_cache_mode =
  force_generic_plan`, under which both collapsed to `Seq Scan (rows=708762)`. So they also
  depended on `prepare: :unnamed` (set on all three repos) to get custom plans. Neither is a
  deliberate guarantee about these queries.

  These pay off where the equivalent index on `relates_to` would NOT (see the #575 closing
  note): the target subsets are tiny. `potential_conflict` is 15,617 rows of 1,417,624 (1.1%)
  and `contradicts` is 0, against `relates_to`'s 98.9% — a partial index earns its keep
  exactly when its predicate is selective.

  Applied out-of-band with CREATE INDEX CONCURRENTLY on prod first (the migration runner wraps
  each migration in one transaction, and Postgres forbids CONCURRENTLY inside one), then
  codified here in the guarded plain form: a no-op where the catalog already matches, instant
  on a fresh/CI database.

  Measured on production, before -> after:

    * `find_contradiction_clusters/2`  313 ms -> 0.131 ms   (index is 8 kB — it covers 0 rows)
    * `list_potential_conflicts/2` count  142 ms -> 60.7 ms  (index is 912 kB)
    * `list_potential_conflicts/2` page   142 ms -> 0.464 ms, and the `Sort` node is GONE

  The page index column order is load-bearing: `((metadata->>'similarity_score')::float) DESC,
  id` matches what the query's `order_by` emits (`desc:` renders as `DESC`, i.e. DESC NULLS
  FIRST, and PostgreSQL's index `DESC` defaults to NULLS FIRST too). Build it any other way —
  notably `NULLS LAST` — and the planner silently will not use it for the ordering, falling
  back to a sort over the whole filtered set.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS article_links_potential_conflict_idx
      ON article_links (tenant_id, ((metadata->>'similarity_score')::float) DESC, id)
      WHERE relationship_type = 'potential_conflict'
        AND (metadata->>'auto_generated') = 'true'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS article_links_contradicts_idx
      ON article_links (tenant_id, source_article_id, target_article_id)
      WHERE relationship_type = 'contradicts'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS article_links_potential_conflict_idx")
    execute("DROP INDEX IF EXISTS article_links_contradicts_idx")
  end
end
