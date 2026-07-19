defmodule Loopctl.Repo.Migrations.DropRedundantChannelPostsRecentIdx do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # US-40.A3 — write-amplification cleanup.
  #
  # The create migration (20260717020000_create_channel_posts.exs:37-39) added a
  # recency btree `channel_posts_recent_idx` on
  # `(tenant_id, project_id, inserted_at DESC)`. The later hardening migration
  # (20260718000000_harden_channel_posts_slot_and_ordering.exs:34-36) added a
  # strict SUPERSET `channel_posts_recent_seq_idx` on
  # `(tenant_id, project_id, inserted_at DESC, seq DESC)` but never dropped the
  # old one — so every insert maintained two overlapping btrees.
  #
  # `recent_page/3` (coordination.ex) orders `inserted_at DESC, seq DESC` and is
  # fully served by the seq index; the old prefix index is dead weight. This drops
  # it. Explicit up/down (not `change`) because a raw CONCURRENTLY execute and a
  # differently-shaped down are involved.
  #
  # DROP/CREATE INDEX CONCURRENTLY (outside a DDL transaction, migration lock
  # disabled) so neither direction takes an ACCESS EXCLUSIVE / SHARE lock that
  # blocks reads or writes on the hot `channel_posts` table (one post per
  # session-turn across a fleet). A cleanup whose entire purpose is to REDUCE the
  # write-path cost on the hottest write table must not itself stall that write
  # path at deploy time. Mirrors the repo's documented CONCURRENTLY convention —
  # 20260713010000_add_oban_jobs_ingestion_tenant_index.exs,
  # 20260713020000_widen_oban_jobs_ingestion_index_to_composite.exs, and
  # 20260717190000_add_articles_source_type_index.exs. `IF EXISTS`/`IF NOT EXISTS`
  # keep both directions idempotent-safe.

  # up/0 (AC-40.A3.1, AC-40.A3.2 idempotent-safe): drop the redundant prefix index
  # CONCURRENTLY. `IF EXISTS` so a fresh DB that never had it (were the create
  # migration ever consolidated) does not fail.
  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS channel_posts_recent_idx")
  end

  # down/0 (AC-40.A3.2 reversible): recreate EXACTLY as the create migration declared
  # it (20260717020000_create_channel_posts.exs:37-39) — same columns, same name —
  # CONCURRENTLY so the rebuild does not block writes to the hot table.
  def down do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS channel_posts_recent_idx
    ON channel_posts (tenant_id, project_id, inserted_at DESC)
    """)
  end
end
