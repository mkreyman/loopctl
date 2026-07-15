defmodule Loopctl.Repo.Migrations.AddMemoriesPendingEmbeddingIndex do
  use Ecto.Migration

  # US-37.4 (review HIGH #1): the periodic pending-embedding sweep enumerates
  # tenants that still have un-embedded long-term memories
  # (`Memory.tenant_ids_with_pending_embeddings/0` — `DISTINCT tenant_id WHERE
  # embedding IS NULL`). This partial index keeps that backstop (and the
  # per-tenant `list_memories_pending_embedding/2` reader) an index scan rather
  # than a seq scan over the whole memories table on every sweep tick.

  def change do
    create index(:memories, [:tenant_id, :inserted_at, :id],
             where: "embedding IS NULL",
             name: :memories_pending_embedding_idx
           )
  end
end
