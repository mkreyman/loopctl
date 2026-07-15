defmodule Loopctl.Repo.Migrations.SeedEmbeddingBatchTuningConfigs do
  use Ecto.Migration

  # US-37.4 (review): seed the live-tunable knobs added to bound and time the
  # background embedding BATCH path beyond the simple count cap.
  #
  #   * embedding_batch_max_chars — cumulative per-request CHARACTER budget so a
  #     chunk of large-text articles is sub-split before it can exceed an
  #     OpenAI-compatible per-request TOKEN ceiling (which the count cap alone can't
  #     guarantee). ~1,000,000 chars ≈ 250k tokens, comfortably under ~300k.
  #   * embedding_batch_yield_base_ms / _per_item_ms — the worker's Task.yield budget
  #     (base + per-input), scaled by array size so a large batch gets proportionally
  #     more slack than one text.
  #   * embedding_batch_receive_base_ms / _per_item_ms — the client's batch-path Req
  #     receive_timeout (base + per-input). Base kept BELOW the yield base so the HTTP
  #     call fails cleanly before the worker's yield shuts the task down.
  #
  # Read on the hot path via SystemConfig.get_int/2; a missing row falls back to the
  # in-code default (safe degrade), so seeding here only makes the values
  # operator-visible/tunable from day one. Global table, AdminRepo-only. ON CONFLICT
  # keeps re-runs safe.
  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'embedding_batch_max_chars', 1000000,
          'Cumulative per-request character budget for a background embedding array call',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_batch_yield_base_ms', 8000,
          'BatchArticleEmbeddingWorker Task.yield base budget (ms)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_batch_yield_per_item_ms', 100,
          'BatchArticleEmbeddingWorker Task.yield per-input slack (ms)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_batch_receive_base_ms', 6000,
          'EmbeddingClient batch-path Req receive_timeout base (ms)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_batch_receive_per_item_ms', 100,
          'EmbeddingClient batch-path Req receive_timeout per-input slack (ms)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key IN (
        'embedding_batch_max_chars',
        'embedding_batch_yield_base_ms', 'embedding_batch_yield_per_item_ms',
        'embedding_batch_receive_base_ms', 'embedding_batch_receive_per_item_ms'
      )
      """
    )
  end
end
