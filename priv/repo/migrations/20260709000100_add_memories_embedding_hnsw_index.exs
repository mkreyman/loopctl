defmodule Loopctl.Repo.Migrations.AddMemoriesEmbeddingHnswIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # HNSW cosine index on `memories.embedding`, mirroring
  # `AddEmbeddingHnswIndex` for `articles`. The capability-based
  # (`amname = 'hnsw'`) detection/create/drop SQL lives in
  # `Loopctl.Repo.HnswIndex`, parameterized by table name — so this migration is
  # asserted present BY CAPABILITY, never by a hard-coded index name (tolerating
  # prod name drift, AC-28.1.3).

  def up do
    execute(Loopctl.Repo.HnswIndex.create_if_absent_sql("memories"))
  end

  def down do
    execute(Loopctl.Repo.HnswIndex.drop_all_sql("memories"))
  end
end
