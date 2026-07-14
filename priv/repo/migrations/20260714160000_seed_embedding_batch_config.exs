defmodule Loopctl.Repo.Migrations.SeedEmbeddingBatchConfig do
  use Ecto.Migration

  # US-37.4 (#352): background embedding batch-size knob.
  #
  # `embedding_batch_max` caps how many texts the per-tenant BatchEmbeddingWorker
  # sends in ONE OpenAI-compatible array call (`input: [...]`). At ~100 this cuts
  # provider round-trips ~100x under bulk ingest while each batch still takes
  # exactly one US-37.1 admission token.
  #
  # A missing row makes SystemConfig.get_int/2 fall back to the in-code default
  # (100 in Loopctl.Workers.BatchEmbeddingWorker), so seeding here only mirrors that
  # default into the DB from day one, operator-visible and live-tunable (no deploy).
  # `now() AT TIME ZONE 'UTC'` matches the :utc_datetime_usec columns; ON CONFLICT
  # keeps re-runs safe.

  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'embedding_batch_max', 100,
          'Max texts per background embedding array call (BatchEmbeddingWorker); one admission token per batch',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key = 'embedding_batch_max'
      """
    )
  end
end
