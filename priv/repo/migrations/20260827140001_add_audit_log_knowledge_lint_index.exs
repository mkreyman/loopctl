defmodule Loopctl.Repo.Migrations.AddAuditLogKnowledgeLintIndex do
  use Ecto.Migration

  @moduledoc """
  Partial index over the nightly knowledge-lint completion events, so the
  `:consumer_stalled` dead-man's-switch (#765 item 6) can read them CROSS-TENANT
  without a sequential scan of `audit_log`.

  `Loopctl.Knowledge.IngestionHealth.detect_consumer_stalled_scan/1` reads the last
  N `knowledge.lint_completed` rows PER TENANT. The existing indexes cannot serve
  that: `audit_log_tenant_entity_idx` leads on `tenant_id` (useless without one),
  and `audit_log_tenant_inserted_at_idx` would hand back every audit row a tenant
  wrote in the window to filter `entity_type` on the heap.

  The predicate is deliberately on `entity_type` alone rather than on the
  `(entity_type, action)` pair: `"knowledge_lint"` is written by exactly one
  producer, so it is already ~1 row per tenant per night, and a second lint ACTION
  added later stays indexed instead of silently falling back to a scan.

  ## Locking

  `audit_log` is a RANGE-partitioned parent, and `CREATE INDEX CONCURRENTLY` is not
  supported on a partitioned parent — so this takes a `SHARE` lock per partition
  while it builds, blocking audit WRITES (and therefore mutating API requests) for
  the duration. That is the same trade `20260403232059_add_audit_log_metadata_story_id_index`
  already made on this table. The build is a scan of the retained partitions with
  almost nothing written, because the predicate matches ~one row per tenant per night.

  Future partitions inherit it: `AuditPartitionWorker` creates them with
  `CREATE TABLE ... PARTITION OF`, which materialises every parent index.
  """

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS audit_log_knowledge_lint_idx
      ON audit_log (tenant_id, inserted_at DESC)
      WHERE entity_type = 'knowledge_lint'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS audit_log_knowledge_lint_idx")
  end
end
