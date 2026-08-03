defmodule Loopctl.Repo.Migrations.CreateEmbeddingRetirementObservations do
  use Ecto.Migration

  # GH #551: the daily evidence trail behind the US-41.1 legacy-column retirement
  # trigger (`Loopctl.Embeddings.LegacyRetirement`). GLOBAL (non-tenant) like
  # `system_configs`: what it records is a property of the DEPLOYMENT's schema and
  # index usage, not of any tenant.
  #
  # Per CLAUDE.md rule 4 we ENABLE (never FORCE) Row Level Security, with no
  # tenant_isolation policy: there is no tenant_id to scope by, and all access goes
  # through `Loopctl.AdminRepo` (BYPASSRLS in prod, table owner in dev/test). RLS
  # therefore simply denies the low-privilege `Loopctl.Repo` role, which never
  # touches this table.
  #
  # Why a table at all, rather than reading `pg_stat_user_indexes` once at decision
  # time: `idx_scan` is a CUMULATIVE counter. "Zero scans over the last N days" is a
  # DELTA, and a delta needs a stored earlier reading. `stats_reset_at` is captured
  # alongside it so a `pg_stat_reset()` (which zeroes the counters and would
  # otherwise read as a suspiciously quiet window) invalidates the window instead of
  # fabricating evidence.
  #
  # `observed_on` is UNIQUE: exactly one observation per UTC day, so a re-run of the
  # daily cron (Oban retry, redeploy, manual invocation) UPSERTS rather than
  # inflating the record count. The streak is counted in DAYS, and duplicate rows for
  # a single day would let one day masquerade as a long quiet stretch.

  def change do
    create table(:embedding_retirement_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :observed_on, :date, null: false
      add :observed_at, :utc_datetime_usec, null: false

      # The value the READ PATH sees (`SystemConfig` "embedding_side_table_reads"),
      # not a re-derivation of it: 1 = side table, 0 = legacy column.
      add :side_table_reads, :integer, null: false

      # WHICH legacy columns still exist, e.g. ["articles", "memories"]. A list
      # rather than a boolean so a half-completed retirement is legible.
      add :legacy_columns_present, {:array, :string}, null: false, default: []

      # index_name => cumulative idx_scan, for every index over a legacy `embedding`
      # column. Discovered BY COLUMN, never by name, so a renamed or newly added
      # legacy index cannot slip out of the window unnoticed.
      add :legacy_index_scans, :map, null: false, default: %{}

      # pg_stat_database.stats_reset at observation time. A change across the window
      # makes every counter delta in it meaningless.
      add :stats_reset_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embedding_retirement_observations, [:observed_on])

    execute(
      "ALTER TABLE embedding_retirement_observations ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE embedding_retirement_observations DISABLE ROW LEVEL SECURITY"
    )
  end
end
