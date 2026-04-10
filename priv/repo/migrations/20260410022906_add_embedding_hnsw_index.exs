defmodule Loopctl.Repo.Migrations.AddEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    execute(
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS articles_embedding_idx ON articles USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS articles_embedding_idx"
    )
  end
end
