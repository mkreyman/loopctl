defmodule Loopctl.Repo.Migrations.AddSessionMemoriesPromotionSweepIndex do
  use Ecto.Migration

  # Epic 29 (Agent Memory, Part 2 / auto-promotion), US-29.2 review hardening.
  #
  # `Loopctl.Workers.MemoryPromotionSweepWorker` enumerates promotion candidates with
  # ONE scoped aggregate (NOT a per-tenant fan-out): a
  # `GROUP BY (tenant_id, subject_id, session_id)` over `session_memories`, LEFT JOINed
  # to `session_promotions`, with a `HAVING` that drops sessions whose newest turn
  # (`max(inserted_at)`) does not exceed the watermark's `last_turn_inserted_at`, ordered
  # `asc: max(inserted_at)` (oldest-active first), then `LIMIT`ed.
  #
  # The only btrees on `session_memories` are (tenant_id, subject_id, seq)
  # (20260709000200) and whatever create_memory_stores added — neither supports the
  # group/aggregate over (tenant_id, subject_id, session_id) with an inserted_at
  # min/max, so every sweep tick would trigger a full scan + external aggregate that
  # degrades linearly as the table grows. This composite index exactly matches the
  # aggregate's grouping keys plus the aggregated column, so the planner can serve the
  # grouped/min-max scan from the index.
  #
  # CONCURRENTLY (no table lock) since `session_memories` is a live OLTP write path; the
  # migration lock + DDL transaction are disabled because CREATE INDEX CONCURRENTLY
  # cannot run inside a transaction. Purely additive — safe on the live prod DB.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "session_memories_promotion_sweep_index"

  def up do
    # A CREATE INDEX CONCURRENTLY that fails midway (crash, lock timeout, deploy killed)
    # leaves a permanently-INVALID index behind. On the next deploy, `IF NOT EXISTS`
    # matches that invalid leftover BY NAME and skips the rebuild — the migration records
    # as complete while the index stays unusable and every sweep silently full-scans.
    # Dropping any leftover FIRST (also CONCURRENTLY, IF EXISTS so a clean DB is a no-op)
    # guarantees the CREATE always rebuilds from a known-clean state. Two separate
    # statements are required — each CONCURRENTLY op runs outside a transaction, which is
    # why @disable_ddl_transaction is set.
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON session_memories (tenant_id, subject_id, session_id, inserted_at)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
