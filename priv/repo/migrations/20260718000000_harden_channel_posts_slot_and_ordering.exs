defmodule Loopctl.Repo.Migrations.HardenChannelPostsSlotAndOrdering do
  use Ecto.Migration

  # Applies two channel_posts hardenings to EVERY environment (including those
  # that already ran 20260717020000 from #425, which is never re-run):
  #
  # 1. Slot isolation: rebuild the keyed-slot unique index to include the
  #    server-stamped `agent_id`, so a spoofed, client-supplied `session_id` can
  #    never collide with (US-39.1) — nor, once US-39.2 adds the on_conflict
  #    upsert, overwrite — another agent's working-state slot. The isolation must
  #    not rest on the spoofable `session_id` alone.
  #
  # 2. Deterministic newest-first ordering: add a monotonic `seq` (bigserial) so
  #    `recent/3` (and US-39.3 cursor pagination) can tie-break same-microsecond
  #    inserts by true insertion order instead of a random v4 UUID.

  def up do
    drop index(:channel_posts, [:tenant_id, :project_id, :session_id, :key],
           name: :channel_posts_session_key_uidx
         )

    create unique_index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
             where: "key IS NOT NULL",
             name: :channel_posts_session_key_uidx
           )

    # bigserial: DB-generated, gap-tolerant, strictly increasing with insert order.
    alter table(:channel_posts) do
      add :seq, :bigserial, null: false
    end

    # Newest-first reads tie-break on seq; index the ordering columns for the
    # recent-reads path (WHERE tenant_id/project_id ORDER BY inserted_at DESC, seq DESC).
    create index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC", "seq DESC"],
             name: :channel_posts_recent_seq_idx
           )
  end

  def down do
    drop index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC", "seq DESC"],
           name: :channel_posts_recent_seq_idx
         )

    alter table(:channel_posts) do
      remove :seq
    end

    drop index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
           name: :channel_posts_session_key_uidx
         )

    create unique_index(:channel_posts, [:tenant_id, :project_id, :session_id, :key],
             where: "key IS NOT NULL",
             name: :channel_posts_session_key_uidx
           )
  end
end
