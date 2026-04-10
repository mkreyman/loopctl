defmodule Loopctl.Repo.Migrations.AddEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Only create the HNSW index if the embedding column exists (pgvector was enabled)
    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'articles' AND column_name = 'embedding') THEN
          IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'articles_embedding_idx') THEN
            CREATE INDEX articles_embedding_idx ON articles USING hnsw (embedding vector_cosine_ops);
          END IF;
        END IF;
      END $$;
      """,
      "DROP INDEX IF EXISTS articles_embedding_idx"
    )
  end
end
