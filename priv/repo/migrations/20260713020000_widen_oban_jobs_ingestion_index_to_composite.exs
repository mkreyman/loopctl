defmodule Loopctl.Repo.Migrations.WidenObanJobsIngestionIndexToComposite do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc false
  # Widens oban_jobs_ingestion_tenant_idx (added in 20260713010000) from a single-column
  # partial expression index on (args->>'tenant_id') to a COMPOSITE partial index on
  #   ((args->>'tenant_id'), inserted_at DESC, id DESC)  WHERE worker = ContentIngestionWorker
  #
  # WHY (US-34.6 review finding): GET /api/v1/knowledge/ingestion-jobs runs two queries on
  # this predicate (`list_ingestion_jobs/2` in KnowledgeIngestionController):
  #   COUNT: worker = ContentIngestionWorker AND args->>'tenant_id' = $1
  #   LIST : same filter, ORDER BY inserted_at DESC, id DESC  LIMIT $2 OFFSET $3
  # The original single-column index backed the COUNT/filter but carried no ordering
  # column, so for a tenant with a large ingestion history the planner index-seeked the
  # tenant's rows and then performed a FULL Sort before the Limit (O(N log N) in that
  # tenant's job count). The composite index carries the exact ORDER BY columns
  # (inserted_at DESC, id DESC) after the equality-matched leading column, so the ordered
  # page is answered by an ordered Index Scan feeding Limit — NO Sort node. The COUNT still
  # uses the composite's leading column (Bitmap Index Scan), so AC-34.6.1 stays satisfied
  # with ONE index instead of two overlapping indexes on the hot, Oban-owned oban_jobs
  # table. Same index name is preserved so the AC-34.6.1 tests and callers are unaffected.
  #
  # CAPTURED EXPLAIN EVIDENCE (natural planner choice, enable_seqscan ON) against a
  # realistically-populated oban_jobs (~60k ingestion rows across 50 tenants, post-ANALYZE;
  # run in a rolled-back transaction on the dev DB — resolves the "eligibility vs natural
  # selection" verification gate for AC-34.6.1):
  #
  #   COUNT:
  #     Aggregate
  #       ->  Bitmap Heap Scan on oban_jobs
  #             Recheck Cond: ((args ->> 'tenant_id') = 'tenant-7') AND (worker = ContentIngestionWorker)
  #             ->  Bitmap Index Scan on oban_jobs_ingestion_tenant_idx
  #                   Index Cond: ((args ->> 'tenant_id') = 'tenant-7')
  #   LIST (ORDER BY inserted_at DESC, id DESC LIMIT 20):
  #     Limit
  #       ->  Index Scan using oban_jobs_ingestion_tenant_idx on oban_jobs
  #             Index Cond: ((args ->> 'tenant_id') = 'tenant-7')
  #     -- NO Sort node: the composite index supplies the ordering.
  #
  # Built CONCURRENTLY (outside a ddl transaction) so the rebuild does not block writes to
  # the hot oban_jobs table online. Fully reversible: down() restores the single-column
  # index of 20260713010000.

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_ingestion_tenant_idx")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_ingestion_tenant_idx
    ON oban_jobs (((args->>'tenant_id')), inserted_at DESC, id DESC)
    WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS oban_jobs_ingestion_tenant_idx")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS oban_jobs_ingestion_tenant_idx
    ON oban_jobs (((args->>'tenant_id')))
    WHERE worker = 'Loopctl.Workers.ContentIngestionWorker'
    """)
  end
end
