defmodule Loopctl.Repo.Migrations.AddEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Only create the HNSW index if the embedding column exists (pgvector was enabled)
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'articles' AND column_name = 'embedding') THEN
        IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'articles_embedding_idx') THEN
          CREATE INDEX articles_embedding_idx ON articles USING hnsw (embedding vector_cosine_ops);
        END IF;
      END IF;
    END $$;
    """)
  end

  def down do
    # AC-27.14.2: drop WHICHEVER hnsw index is actually present on
    # articles(embedding), detected by access method (amname='hnsw'), NOT by
    # a hard-coded name. The original down-step was
    # `DROP INDEX IF EXISTS articles_embedding_idx`, which silently NO-OPs
    # against prod's out-of-band `articles_embedding_hnsw_idx` — a rollback
    # that would leave the live index orphaned. This handles either name.
    execute("""
    DO $$
    DECLARE idx text;
    BEGIN
      SELECT i.relname INTO idx
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_am    am ON am.oid = i.relam
      WHERE t.relname = 'articles' AND am.amname = 'hnsw'
      LIMIT 1;

      IF idx IS NOT NULL THEN
        EXECUTE format('DROP INDEX IF EXISTS %I', idx);
      END IF;
    END $$;
    """)
  end
end
