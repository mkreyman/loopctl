defmodule Loopctl.Repo.Migrations.DropRedundantChannelPostsRecentIdx do
  use Ecto.Migration

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
  # it. Explicit up/down (not `change`) because `drop_if_exists` and a
  # differently-shaped down are involved.

  # up/0 (AC-40.A3.1, AC-40.A3.2 idempotent-safe): drop the redundant prefix index.
  # `drop_if_exists` so a fresh DB that never had it (were the create migration ever
  # consolidated) does not fail.
  def up do
    drop_if_exists index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC"],
                     name: :channel_posts_recent_idx
                   )
  end

  # down/0 (AC-40.A3.2 reversible): recreate EXACTLY as the create migration declared
  # it (20260717020000_create_channel_posts.exs:37-39) — same columns, same name.
  def down do
    create index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC"],
             name: :channel_posts_recent_idx
           )
  end
end
