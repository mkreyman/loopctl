defmodule Loopctl.Repo.Migrations.AddEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Only create the HNSW index if the embedding column exists (pgvector was
    # enabled). AC-27.14.2: the existence guard is capability-based (ANY hnsw
    # index on articles already present), symmetric with down/0's amname-based
    # detection — NOT a hard-coded `indexname = 'articles_embedding_idx'`
    # check. The old name-based guard only saw the migration's own name, so
    # from prod's drift state {articles_embedding_hnsw_idx} this up-step would
    # create a SECOND, redundant hnsw index. By skipping when any hnsw index on
    # articles(embedding) exists (detected by am.amname='hnsw', the same
    # pg_index/pg_am join down/0 and the reconcile migration use), the two-index
    # state can never arise.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'articles' AND column_name = 'embedding') THEN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_index x
          JOIN pg_class i ON i.oid = x.indexrelid
          JOIN pg_class t ON t.oid = x.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN pg_am    am ON am.oid = i.relam
          WHERE t.relname = 'articles' AND n.nspname = 'public' AND am.amname = 'hnsw'
        ) THEN
          CREATE INDEX articles_embedding_idx ON articles USING hnsw (embedding vector_cosine_ops);
        END IF;
      END IF;
    END $$;
    """)
  end

  def down do
    # AC-27.14.2: drop ALL hnsw indexes actually present on articles(embedding),
    # detected by access method (amname='hnsw'), NOT by a hard-coded name. The
    # original down-step was `DROP INDEX IF EXISTS articles_embedding_idx`,
    # which silently NO-OPs against prod's out-of-band
    # `articles_embedding_hnsw_idx` — a rollback that would leave the live index
    # orphaned. Iterating over EVERY hnsw index (rather than `LIMIT 1`) means
    # that even if multiple hnsw indexes somehow coexist, the down-step leaves
    # none orphaned.
    execute("""
    DO $$
    DECLARE idx text;
    BEGIN
      FOR idx IN
        SELECT i.relname
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class t ON t.oid = x.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am    am ON am.oid = i.relam
        WHERE t.relname = 'articles' AND n.nspname = 'public' AND am.amname = 'hnsw'
      LOOP
        EXECUTE format('DROP INDEX IF EXISTS %I', idx);
      END LOOP;
    END $$;
    """)
  end
end
