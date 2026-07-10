defmodule Loopctl.Repo.Migrations.AddMemoriesLiveEmbeddingPartialHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # US-28.2 (recall superseded-crowding fix). The FULL HNSW index on
  # `memories.embedding` (`AddMemoriesEmbeddingHnswIndex`) also contains SUPERSEDED
  # rows — a superseded memory keeps its `vector(1536)` embedding. `Loopctl.Memory`'s
  # default `recall/2` over-fetches the top-`pool` nearest-by-cosine and then applies
  # the subject scope + `superseded_by IS NULL` exclusion on the OUTER query. A
  # long-lived subject that repeatedly supersedes can fill that top-`pool` with
  # still-embedded superseded near-neighbours, so the outer exclusion drops them and
  # default recall UNDER-FILLS — returning fewer than `k` (or zero) LIVE rows even
  # though live memories exist corpus-wide.
  #
  # This PARTIAL HNSW index over only LIVE rows (`WHERE superseded_by IS NULL`) keeps
  # the default-recall pool full of recallable rows: `Loopctl.Memory`'s recall inner
  # adds `WHERE superseded_by IS NULL`, and because that query predicate EXACTLY
  # matches this index's predicate, the planner serves the ANN from this partial index
  # WITHOUT defeating HNSW (superseded rows are simply not IN the index, so they can't
  # occupy pool slots). `include_superseded: true` recall keeps using the full index
  # (`AddMemoriesEmbeddingHnswIndex`).
  #
  # Detected by EXACT NAME (not by `amname = 'hnsw'` capability, which the sibling
  # full-index migration uses) because there are now intentionally TWO HNSW indexes on
  # `memories.embedding` — a capability check would see the full index and skip this.

  @index "memories_live_embedding_hnsw_idx"

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'memories' AND column_name = 'embedding'
      ) THEN
        IF NOT EXISTS (
          SELECT 1 FROM pg_class i
          JOIN pg_namespace n ON n.oid = i.relnamespace
          WHERE i.relname = '#{@index}' AND n.nspname = 'public'
        ) THEN
          CREATE INDEX #{@index} ON memories
            USING hnsw (embedding vector_cosine_ops)
            WHERE superseded_by IS NULL;
        END IF;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index}")
  end
end
