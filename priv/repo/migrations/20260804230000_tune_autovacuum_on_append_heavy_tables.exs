defmodule Loopctl.Repo.Migrations.TuneAutovacuumOnAppendHeavyTables do
  @moduledoc """
  Per-table autovacuum tuning for the append-heavy tables (#579).

  Autoanalyze had NEVER run on the four largest tables — `autoanalyze_count = 0`,
  `last_autoanalyze IS NULL` — so `pg_stat_user_tables` reported row counts wrong by three
  orders of magnitude: `articles` said 358 against a real 85,053, `article_links` said 6,026
  against 1,417,624. Anything reading `n_live_tup` (capacity checks, dashboards) was simply
  wrong, and column statistics age silently with the data.

  Not a broken autovacuum — `autovacuum` is `on` and no table disables it. A THRESHOLD gap:
  the trigger is `50 + 0.1 * reltuples`, i.e. ~8,555 changes for `articles`. The corpus was
  bulk-loaded at the 2026-07-30 consolidation and has grown by less than that since, so it
  legitimately never fired. Only `oban_jobs`, which churns constantly, was being analyzed.

  These tables ACCUMULATE rather than churn (`n_dead_tup` measured ~0 on `article_links`,
  `article_access_events`; 475 on `articles`), so the INSERT-driven trigger is the right knob,
  not the update-churn `autovacuum_vacuum_scale_factor`. Halving the analyze scale factor
  takes `articles` from ~8,555 changes to ~4,303 and `article_access_events` to ~2,868.

  Catalog-only (instant, no rewrite), so it rides a normal migration rather than needing the
  out-of-band DDL procedure.

  NOT applied to the `audit_log` PARENT: a partitioned parent has no heap and rejects storage
  autovacuum params. Partitions are stamped individually here, and — because a
  `CREATE TABLE ... PARTITION OF` child does NOT inherit reloptions —
  `Loopctl.Workers.AuditPartitionWorker` stamps every partition it creates, self-healingly.
  A table REBUILD also silently drops reloptions, so re-apply after any copy-swap.
  """
  use Ecto.Migration

  @append_heavy ~w(articles article_links article_embeddings article_access_events)

  # `analyze` halved from the 0.1 default; `vacuum_insert` at 0.1 so an append-only table is
  # still vacuumed for the visibility map (index-only scans) without waiting on dead tuples
  # that never come.
  @opts "autovacuum_analyze_scale_factor = 0.05, autovacuum_vacuum_insert_scale_factor = 0.1"

  def up do
    for table <- @append_heavy do
      execute("ALTER TABLE #{table} SET (#{@opts})")
    end

    # Existing audit_log partitions (leaves only — the parent has no heap).
    execute("""
    DO $$
    DECLARE part text;
    BEGIN
      FOR part IN
        SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE p.relname = 'audit_log' AND c.relkind = 'r'
      LOOP
        EXECUTE format('ALTER TABLE %I SET (#{@opts})', part);
      END LOOP;
    END $$
    """)
  end

  def down do
    reset = "autovacuum_analyze_scale_factor, autovacuum_vacuum_insert_scale_factor"

    for table <- @append_heavy do
      execute("ALTER TABLE #{table} RESET (#{reset})")
    end

    execute("""
    DO $$
    DECLARE part text;
    BEGIN
      FOR part IN
        SELECT c.relname
          FROM pg_inherits i
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_class c ON c.oid = i.inhrelid
         WHERE p.relname = 'audit_log' AND c.relkind = 'r'
      LOOP
        EXECUTE format('ALTER TABLE %I RESET (#{reset})', part);
      END LOOP;
    END $$
    """)
  end
end
