defmodule Loopctl.Repo.Migrations.AddArticlesPublishedReconciliationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  A partial index that lets the hourly embedding-reconciliation anti-join
  (`Loopctl.Embeddings.unembedded_articles/2`) answer "is any published article missing an
  embedding" WITHOUT touching the articles heap.

  Measured on the hosted corpus 2026-08-25, warm cache, 86,476 articles / 85,559 embeddings:

  | shape                                    | shared buffers | time   |
  |------------------------------------------|----------------|--------|
  | before                                   | 40,968         | ~400ms |
  | id-only anti-join, no index               | 19,320         | ~140ms |
  | id-only anti-join, this index             | 1,181          |  ~76ms |

  The index COLUMNS are what the anti-join reads (`tenant_id` and `id` to compare,
  `inserted_at` for its oldest-first ordering), so the scan is Index Only with zero Heap
  Fetches. The index PREDICATE carries the caller's filters — published, and a non-blank
  body — because `length(btrim(body))` has to DETOAST every body it evaluates: as a scan
  predicate it read the whole heap plus its TOAST, and as an index predicate it is settled
  at write time. Keeping the filters in the index (rather than dropping them from the
  query) is what preserves the LIMIT's meaning: it still counts genuinely embeddable
  articles, so a backlog of empty-bodied ones cannot mask a real gap behind it.

  Spell the predicate in `unembedded_article_ids/2` EXACTLY as it is spelled here. The
  planner uses a partial index only when it can prove the query implies the predicate, and
  an equivalent-but-differently-written rewrite on either side silently costs the heap back.

  4.6 MB on the hosted corpus. CONCURRENTLY so the build does not block writes to articles.
  """

  def change do
    create index(:articles, [:tenant_id, :inserted_at, :id],
             name: :articles_tenant_embeddable_inserted_id_idx,
             where: "status = 'published' AND body IS NOT NULL AND length(btrim(body)) > 0",
             concurrently: true
           )
  end
end
