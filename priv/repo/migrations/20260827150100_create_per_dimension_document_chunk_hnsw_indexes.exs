defmodule Loopctl.Repo.Migrations.CreatePerDimensionDocumentChunkHnswIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  US-43.1 AC-43.1.5.

  Pre-creates ONE partial HNSW expression index per SUPPORTED dimension on
  `document_chunk_embeddings`, `CREATE INDEX CONCURRENTLY` (hence
  `@disable_ddl_transaction` + `@disable_migration_lock`, and hence a SEPARATE
  migration file from the table creation — CONCURRENTLY cannot run inside the DDL
  transaction that migration uses).

  The SQL comes from `Loopctl.Repo.HnswIndex.create_dimension_index_sql/2`, the
  SAME generator the article and memory side tables use, for two reasons that are
  not cosmetic: the `(embedding::vector(N))` cast must stay CHARACTER-IDENTICAL
  between the index and the query or the planner cannot match them, and the build
  parameters `m` / `ef_construction` cannot drift between tiers.

  `document_chunk_embeddings` is also added to `HnswIndex`'s `@side_tables`, so
  `missing_dimension_indexes/1` — the drift guard for "a dimension was PUBLISHED in
  config and `.well-known` but never index-built" — covers the corpus tier too. That
  misconfiguration is invisible to the compile-time supported-set guard yet makes
  every read at that dimension sequential-scan the whole corpus: the #170/#172
  outage class.
  """

  @table "document_chunk_embeddings"

  def up do
    for dim <- Loopctl.Embeddings.supported_dimensions() do
      execute(Loopctl.Repo.HnswIndex.create_dimension_index_sql(@table, dim))
    end
  end

  def down do
    for dim <- Loopctl.Embeddings.supported_dimensions() do
      execute(Loopctl.Repo.HnswIndex.drop_dimension_index_sql(@table, dim))
    end
  end
end
