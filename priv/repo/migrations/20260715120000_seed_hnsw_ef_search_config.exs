defmodule Loopctl.Repo.Migrations.SeedHnswEfSearchConfig do
  use Ecto.Migration

  # US-38.4: seed the live-tunable per-query pgvector recall knob `hnsw_ef_search`.
  #
  # `hnsw.ef_search` is the per-QUERY HNSW search breadth (recall ceiling) — raising it
  # inspects more graph nodes per kNN, trading latency for recall. The seeded value 40
  # EQUALS pgvector's default (a deliberate "keep the default" tuning outcome — see
  # docs/hnsw-tuning-evaluation.md), but seeding it makes the knob operator-visible and
  # tunable fleet-wide from day one: an operator raises recall with a single
  # `UPDATE system_configs SET value = 100 WHERE key = 'hnsw_ef_search'` — no redeploy,
  # no per-role `ALTER ROLE`. It is read on the read path by
  # `Loopctl.HeavyRead.hnsw_ef_search/0` (SystemConfig.get_int, persistent_term hot read;
  # a missing row falls back to the in-code default 40, so this seed is a safe no-op if
  # absent) and applied per-ANN-read via `SET LOCAL hnsw.ef_search` inside the existing
  # heavy-read transaction (US-27.13), which is why per-request SET LOCAL is now safe.
  #
  # Global table, AdminRepo-only. ON CONFLICT keeps re-runs safe; DELETE down.
  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'hnsw_ef_search', 40,
          'Per-query pgvector hnsw.ef_search recall breadth, applied via SET LOCAL on ANN heavy reads',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs WHERE key = 'hnsw_ef_search'
      """
    )
  end
end
