defmodule Loopctl.Repo.Migrations.AddMemoryGraduationColumns do
  use Ecto.Migration

  # #411 Gap 3 (PR C): recall-count tracking + graduation of HOT long-term memories
  # into durable knowledge articles.
  #
  #   * `recall_count`    — how many times this memory has been returned by a HEALTHY
  #     semantic recall (the hotness signal the graduation sweep thresholds on). Bumped
  #     OFF the recall hot path (see `Loopctl.Memory.bump_recall_counts/2`), so a bump
  #     failure never affects a recall response.
  #   * `last_recalled_at`— the instant of the most recent counted recall (observability
  #     + a future recency signal). NULL until first recalled.
  #   * `graduated_at`    — set once the memory's content has been graduated to a durable
  #     knowledge article (any novelty-gate verdict — created/gated_to_draft/duplicate/
  #     deduplicated all mean "now durable"). NULL = not yet graduated. The sweep skips
  #     a non-NULL row so a memory is graduated at most once.
  #
  # `*_if_not_exists` on every column/index keeps the migration idempotent/re-runnable.
  #
  # CONCURRENTLY (no table lock) since `memories` is a live, write-hot OLTP table
  # (written on every remember() insert, updated on every recall bump) — a plain
  # CREATE INDEX would take an ACCESS EXCLUSIVE lock for the whole build and stall
  # those writes during deploy. The DDL transaction + migration lock are disabled
  # because CREATE INDEX CONCURRENTLY cannot run inside a transaction, matching the
  # sibling `20260709000400_add_memories_tenant_inserted_at_index.exs` convention on
  # this same table.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "memories_graduation_sweep_idx"

  def up do
    # Adding a column with a CONSTANT default is a fast, metadata-only operation on
    # PG11+ (no table rewrite), so the three column adds do not block writes; only
    # the index build needed CONCURRENTLY.
    alter table(:memories) do
      add_if_not_exists :recall_count, :integer, null: false, default: 0
      add_if_not_exists :last_recalled_at, :utc_datetime_usec, null: true
      add_if_not_exists :graduated_at, :utc_datetime_usec, null: true
    end

    # Partial index backing the graduation sweep's PER-TENANT candidate query
    # (`Loopctl.Workers.MemoryGraduationSweepWorker`): for a given tenant, live,
    # not-yet-graduated memories ordered by hotness. Because the index LEADS with
    # tenant_id, it serves the sweep's `tenant_id = ? ... ORDER BY recall_count DESC`
    # scan (equality + in-index descending order, no sort) but could NOT serve a bare
    # cross-tenant global sort — which is why the sweep queries per tenant and round-robins
    # rather than issuing one global ORDER BY. The predicate matches the sweep's WHERE
    # (`graduated_at IS NULL AND superseded_by IS NULL`) so the index stays small — it
    # only holds rows still eligible for graduation — and it is a plain btree that does
    # NOT touch the HNSW embedding indexes.
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON memories (tenant_id, recall_count)
      WHERE graduated_at IS NULL AND superseded_by IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

    alter table(:memories) do
      remove_if_exists :recall_count, :integer
      remove_if_exists :last_recalled_at, :utc_datetime_usec
      remove_if_exists :graduated_at, :utc_datetime_usec
    end
  end
end
