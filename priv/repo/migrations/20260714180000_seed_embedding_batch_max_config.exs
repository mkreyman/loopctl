defmodule Loopctl.Repo.Migrations.SeedEmbeddingBatchMaxConfig do
  use Ecto.Migration

  # US-37.4: seed the live-tunable `embedding_batch_max` knob (~100) that bounds how
  # many texts the background embedding path sends per provider array call. Read on
  # the hot path via SystemConfig.get_int/2; a missing row falls back to the in-code
  # default (Knowledge.embedding_batch_max/0), so seeding here only makes the value
  # operator-visible/tunable from day one. Global table, AdminRepo-only (see
  # CreateSystemConfigs). ON CONFLICT keeps re-runs safe.
  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'embedding_batch_max', 100,
          'Max texts per background embedding array batch (BatchArticleEmbeddingWorker)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs WHERE key = 'embedding_batch_max'
      """
    )
  end
end
