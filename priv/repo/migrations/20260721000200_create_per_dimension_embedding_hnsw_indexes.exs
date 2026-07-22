defmodule Loopctl.Repo.Migrations.CreatePerDimensionEmbeddingHnswIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  US-41.1 AC-41.1.2 / AC-41.1.3.

  Pre-creates ONE partial HNSW expression index per SUPPORTED dimension on each
  embedding side table, `CREATE INDEX CONCURRENTLY` (hence
  `@disable_ddl_transaction` + `@disable_migration_lock`).

  Index DDL is OPERATOR/MIGRATION PLANE ONLY. Nothing on the request path — no
  controller, no MCP tool, not `set_llm_config` — may issue it: HNSW builds are
  expensive at corpus scale and would be an unbounded request-path cost. The
  instance instead publishes a FIXED supported set on `.well-known/loopctl`
  (`supported_embedding_dimensions`) and the US-41.2 probe rejects anything
  outside it. The published set and the set of indexes created here are BOTH
  derived from `Loopctl.Embeddings.supported_dimensions/0`, so they cannot drift
  (asserted by the TC-41.1.8 test).
  """

  @tables ["article_embeddings", "memory_embeddings"]

  def up do
    for table <- @tables, dim <- Loopctl.Embeddings.supported_dimensions() do
      execute(Loopctl.Repo.HnswIndex.create_dimension_index_sql(table, dim))
    end
  end

  def down do
    for table <- @tables, dim <- Loopctl.Embeddings.supported_dimensions() do
      execute(Loopctl.Repo.HnswIndex.drop_dimension_index_sql(table, dim))
    end
  end
end
