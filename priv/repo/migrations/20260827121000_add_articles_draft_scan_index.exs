defmodule Loopctl.Repo.Migrations.AddArticlesDraftScanIndex do
  @moduledoc """
  A partial index over `status = 'draft'`, so the nightly draft drain stops scanning the
  whole `articles` table to find a handful of rows.

  ## Which query it serves

  `Loopctl.Knowledge.DraftConsumer.candidates/2` — two `SELECT id ... ORDER BY inserted_at
  LIMIT n` passes (oldest-first and newest-first) over `draft_scope/1`. The same index
  serves `Loopctl.Workers.DraftDuplicateSweepWorker`'s `load_embedded_drafts/2` and
  `unembedded_count/1`, whose predicates start the same way.

  It matters more than the row count suggests because of WHERE it runs: `AdminRepo`, whose
  pool is THREE connections (`config/runtime.exs`) and which every authenticated request
  also checks out of. A sequential scan of the articles heap on that pool is not a slow
  query, it is three connections' worth of contention against live traffic — the same
  shape #765's embedding-reconciler scan had (20260825130000), one pool over.

  ## Why the predicate is `status = 'draft'` and nothing more

  `draft_scope/1` carries eight further conditions — tenant, `scope = 'tenant'`, a
  metadata visibility test, `merged_from IS NULL`, an age floor, `consolidation_retracted_at
  IS NULL`, `embedding IS NULL`, and three correlated `NOT EXISTS` subqueries. None of them
  belongs in the index:

    * the planner uses a partial index only when it can PROVE the query implies the
      predicate, so every arm added is an arm that must be spelled identically at both
      sites forever — the trap 20260825130000 documents at length about its `btrim` set,
      and the jsonb `COALESCE(...) NOT IN (...)` visibility test is exactly the shape that
      goes unprovable after an innocuous rewrite;
    * the selectivity is already spent. Drafts were 113 of 86,476 articles on the hosted
      corpus at 2026-08-27 (0.13%), so `status = 'draft'` alone turns a full heap scan into
      a scan of ~113 index entries. Narrowing further removes rows the residuals were going
      to remove for free on a set that size;
    * the age floor is `now()`-relative and so cannot be an index predicate at all.

  Key order `(tenant_id, inserted_at, id)`: `tenant_id` equality first, then the
  `ORDER BY inserted_at` both passes take, with `id` last so the projection is covered and
  the scan stays index-only for the ordering step. Same key shape, and the same reason, as
  `articles_tenant_embeddable_inserted_id_idx`.

  ## Operational shape

  Tiny — a few thousand entries at hosted scale. CONCURRENTLY anyway, so the build cannot
  block writes to `articles`, which costs `@disable_ddl_transaction` +
  `@disable_migration_lock` and raw `execute/1`: Ecto's `create index(concurrently: true)`
  emits no `IF NOT EXISTS`, and an interrupted concurrent build leaves an INVALID index
  that no planner uses and every later deploy trips over. The `ensure_index` guard from
  20260821120000 / 20260825130000 is carried here for that reason — it reconciles SHAPE as
  well as name, so a future correction ships as a FRESH VERSION rather than an edit in
  place (Ecto keys on the version, so an edited migration never re-runs).
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "articles_tenant_draft_inserted_id_idx"

  # Loose on the deparser's parenthesisation and casts (both version dependent — PG renders
  # this predicate as `((status)::text = 'draft'::text)`), exact on key order and on the
  # column and value the predicate tests.
  @shape ~r/USING btree \(tenant_id, inserted_at, id\) WHERE .*status.*=\s*'draft'/s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_draft_inserted_id_idx
    ON articles (tenant_id, inserted_at, id)
    WHERE status = 'draft'
  """

  def up do
    if stale?(), do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")
    execute(@create)
  end

  def down, do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{@name}")

  # Stale = INVALID, a different shape, or ambiguous. Absent is NOT stale: nothing to drop,
  # and the CREATE lays it down.
  defp stale? do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid
      FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case repo().query!(sql, [@name]).rows do
      [[indexdef, true]] -> not (indexdef =~ @shape)
      rows -> rows != []
    end
  end
end
