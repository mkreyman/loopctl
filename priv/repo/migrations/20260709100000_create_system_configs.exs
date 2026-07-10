defmodule Loopctl.Repo.Migrations.CreateSystemConfigs do
  use Ecto.Migration

  # GLOBAL (non-tenant) key/value store for live-tunable operational knobs
  # (timeout/retry budgets). Read on the hot path via :persistent_term; a missing
  # row makes SystemConfig.get_int/2 fall back to the in-code default (safe
  # degrade), so seeding here only makes the values operator-visible/tunable from
  # day one.
  #
  # No tenant_id — this is a global table like `tenants`. Per CLAUDE.md rule 4 we
  # ENABLE (never FORCE) Row Level Security. There is deliberately NO
  # tenant_isolation policy: the table has no tenant_id, and ALL access goes
  # through Loopctl.AdminRepo (BYPASSRLS in prod, table owner in dev/test). RLS
  # therefore simply denies the low-privilege Loopctl.Repo role, which never
  # touches this table.

  def change do
    create table(:system_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :bigint, null: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:system_configs, [:key])

    execute(
      "ALTER TABLE system_configs ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE system_configs DISABLE ROW LEVEL SECURITY"
    )

    # Seed the known knobs with their defaults. NOTE:
    # ingestion_per_chunk_timeout_ms is intentionally 60000 (up from the old
    # hardcoded 30000). `now() AT TIME ZONE 'UTC'` yields a naive UTC timestamp
    # matching the :utc_datetime_usec columns. ON CONFLICT keeps re-runs safe.
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'ingestion_per_chunk_timeout_ms', 60000,
          'Per-chunk LLM extraction timeout budget (ms) for ContentIngestionWorker',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'ingestion_max_job_timeout_ms', 360000,
          'Absolute per-job wall-clock ceiling (ms) for ContentIngestionWorker',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'extraction_receive_timeout_ms', 25000,
          'Anthropic receive_timeout (ms) for ClaudeContentExtractor',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'extraction_max_retries', 1,
          'Anthropic max_retries for ClaudeContentExtractor',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_receive_timeout_ms', 4000,
          'Req receive_timeout (ms) for EmbeddingClient',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'embedding_max_retries', 0,
          'Req max_retries for EmbeddingClient',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key IN (
        'ingestion_per_chunk_timeout_ms', 'ingestion_max_job_timeout_ms',
        'extraction_receive_timeout_ms', 'extraction_max_retries',
        'embedding_receive_timeout_ms', 'embedding_max_retries'
      )
      """
    )
  end
end
