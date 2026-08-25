defmodule Loopctl.Repo.Migrations.AddArticlesPublishedReconciliationIndex do
  @moduledoc """
  A partial index that lets the hourly embedding-reconciliation anti-join
  (`Loopctl.Embeddings.unembedded_articles/2`) answer "is any published article missing an
  embedding" WITHOUT touching the articles heap.

  Measured on the hosted corpus 2026-08-25, warm cache, 86,476 articles / 85,559 embeddings:

  | shape                         | shared buffers | time   |
  |-------------------------------|----------------|--------|
  | before                        | 40,968         | ~400ms |
  | id-only anti-join, no index   | 19,320         | ~140ms |
  | id-only anti-join, this index | 1,181          |  ~76ms |

  The index COLUMNS are what the anti-join reads (`tenant_id` and `id` to compare,
  `inserted_at` for its oldest-first ordering), so the scan is Index Only with zero Heap
  Fetches. The index PREDICATE carries the caller's filters — published, and a non-blank
  body — because `length(btrim(body, ...))` has to DETOAST every body it evaluates: as a
  scan predicate it read the whole heap plus its TOAST, and as an index predicate it is
  settled at write time. Keeping the filters in the index (rather than dropping them from
  the query) is what preserves the LIMIT's meaning: it still counts genuinely embeddable
  articles, so a backlog of empty-bodied ones cannot mask a real gap behind it.

  That placement moves a cost rather than deleting it: `body` is a predicate attribute, so
  a NON-HOT update of a published article re-evaluates the predicate and detoasts the body
  it would not otherwise have read. Article writes are rare next to 24 reconciler runs a
  day per tenant, which is why the trade is taken.

  The second `btrim` argument is load-bearing. Bare `btrim(body)` strips SPACES ONLY, so a
  body of `E'\\n\\t\\n'` reads as non-blank, gets embedded from its title alone, and then
  matches semantic search as if it had content. Spell the predicate in
  `unembedded_article_ids/2` EXACTLY as it is spelled here — the planner uses a partial
  index only when it can prove the query implies the predicate, and an
  equivalent-but-differently-written rewrite on either side silently costs the heap back.

  4.6 MB on the hosted corpus. CONCURRENTLY so the build does not block writes to articles.
  Same `ensure_index/2` guard as 20260821120000: `IF NOT EXISTS` matches on NAME, not
  validity, so an interrupted concurrent build would otherwise leave an INVALID index that
  no planner uses and every later deploy trips over.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name "articles_tenant_embeddable_inserted_id_idx"

  # Loose on the deparser's parenthesisation (version dependent), exact on key order and on
  # every predicate arm — a catalog carrying the space-only `btrim` must read as stale.
  @shape ~r/USING btree \(tenant_id, inserted_at, id\) WHERE .*'published'.*body IS NOT NULL.*btrim\(body, /s

  @create """
  CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_tenant_embeddable_inserted_id_idx
    ON articles (tenant_id, inserted_at, id)
    WHERE status = 'published'
      AND body IS NOT NULL
      AND length(btrim(body, E' \\t\\r\\n')) > 0
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
