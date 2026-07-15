defmodule Loopctl.Repo.Migrations.SeedEmbeddingBatchMaxTokensConfig do
  use Ecto.Migration

  # US-37.4 (review MED #4): background embedding batches must respect the
  # provider's PER-REQUEST token cap, not just the item-count cap
  # (`embedding_batch_max`). An OpenAI-compatible embeddings request rejects an
  # array whose combined token count exceeds ~300k with HTTP 400 — a permanent
  # error that would DISCARD the whole chunk and strand every record in it.
  #
  # `embedding_batch_max_tokens` bounds the ESTIMATED combined tokens
  # (~bytes/4) the BatchEmbeddingWorker packs into one array call; it sub-chunks
  # a fetched batch further when the token budget is hit. Default 200_000 keeps a
  # ~33% headroom under the ~300k provider ceiling to absorb estimation error.
  #
  # A missing row makes SystemConfig.get_int/2 fall back to the in-code default
  # (200_000 in Loopctl.Workers.BatchEmbeddingWorker), so seeding only mirrors the
  # default into the DB — operator-visible and live-tunable, no deploy.

  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'embedding_batch_max_tokens', 200000,
          'Max estimated combined tokens per background embedding array call (BatchEmbeddingWorker); sub-chunks a batch to stay under the provider per-request token cap',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key = 'embedding_batch_max_tokens'
      """
    )
  end
end
