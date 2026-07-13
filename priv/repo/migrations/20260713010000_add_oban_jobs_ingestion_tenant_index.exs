defmodule Loopctl.Repo.Migrations.AddObanJobsIngestionTenantIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # Partial expression index backing GET /api/v1/knowledge/ingestion-jobs (US-34.6):
  #   WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
  #     AND args->>'tenant_id' = $1
  #   -- both the COUNT(*) and the paginated SELECT filter on this predicate.
  #
  # Without this index the query is a seq-scan COUNT over the ever-growing, Oban-owned
  # `oban_jobs` table (Oban's own indexes key on state/queue/scheduled_at, NOT this
  # JSONB expression) — a cost that degrades as job history grows. A partial index on
  # the `(args->>'tenant_id')` expression filtered to the ContentIngestionWorker keeps
  # the index tiny (only ingestion jobs) and lets the planner seek straight to the
  # tenant's rows: EXPLAIN shows an Index Scan, not a Seq Scan.
  #
  # Built CONCURRENTLY (outside a ddl transaction) so the build does not block writes
  # to the hot `oban_jobs` table online. Low blast radius: it does not conflict with
  # Oban's own indexes and is fully reversible.

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_ingestion_tenant_idx")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_ingestion_tenant_idx
    ON oban_jobs (((args->>'tenant_id')))
    WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_ingestion_tenant_idx")
  end
end
