defmodule Loopctl.Repo.Migrations.AddArticleLinksConflictPartialIndexes do
  @moduledoc """
  Two partial indexes on `article_links` for the conflict/contradiction reads (#576, #577).

  Both reads filter on `relationship_type`, the LAST column of
  `article_links_tenant_src_tgt_rel_index` behind two unbounded ones — only PG 18's btree skip
  scan plus `prepare: :unnamed` custom plans kept them off a seq scan, and neither is a
  guarantee. A partial index earns its keep when its predicate is selective, unlike #575's
  `relates_to` (98.9%): `potential_conflict` measured 15,617 rows of 1,417,624 and
  `contradicts` 0, taking the reads 313 ms -> 0.131 ms and 142 ms -> 0.464 ms (`Sort` GONE).

  Built CONCURRENTLY (`@disable_ddl_transaction`/`@disable_migration_lock`, the repo's
  convention — 20260719120000_add_stories_assigned_agent_project_index.exs) so nothing takes a
  write-blocking SHARE lock on the table. IF NOT EXISTS matches the index NAME only, so a
  NULLS LAST hotfix or an INVALID leftover would survive it silently — hence `ensure_index/2`
  reads `pg_get_indexdef`/`indisvalid` and DROPs ONLY a mismatched or invalid index (the
  guard-before-you-destroy convention of 20260624120000_reconcile_hnsw_index_name.exs); an
  already-matching catalog (prod's out-of-band build, a retry) keeps its live index.

  The score column's `DESC` matches the `desc:` the query's `order_by` emits (both NULLS
  FIRST); `NULLS LAST` makes the planner silently sort the whole filtered set instead. Indexing
  the `::float` cast is also a WRITE-PATH invariant — a non-numeric `metadata.similarity_score`
  on a matching row fails the write, and `ArticleLink.changeset/2` does not yet enforce it.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Load-bearing shape per index, as `pg_get_indexdef` renders it: loose on the deparser's
  # parenthesisation (version dependent), exact on key order and predicate.
  @shape %{
    "article_links_potential_conflict_idx" =>
      ~r/USING btree \(tenant_id, .*similarity_score.*DESC, id\) WHERE .*auto_generated/,
    "article_links_contradicts_idx" =>
      ~r/USING btree \(tenant_id, source_article_id, target_article_id\) WHERE .*'contradicts'/
  }

  def up do
    ensure_index("article_links_potential_conflict_idx", """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS article_links_potential_conflict_idx
      ON article_links (tenant_id, ((metadata->>'similarity_score')::float) DESC, id)
      WHERE relationship_type = 'potential_conflict'
        AND (metadata->>'auto_generated') = 'true'
    """)

    ensure_index("article_links_contradicts_idx", """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS article_links_contradicts_idx
      ON article_links (tenant_id, source_article_id, target_article_id)
      WHERE relationship_type = 'contradicts'
    """)
  end

  defp ensure_index(name, create_sql) do
    if stale?(name), do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    # IF NOT EXISTS — an instant no-op when the catalog already matches.
    execute(create_sql)
  end

  # Stale = INVALID, a different shape, or ambiguous. Absent is NOT stale: nothing to drop.
  defp stale?(name) do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid
      FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case repo().query!(sql, [name]).rows do
      [[indexdef, true]] -> not (indexdef =~ @shape[name])
      rows -> rows != []
    end
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS article_links_potential_conflict_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS article_links_contradicts_idx")
  end
end
