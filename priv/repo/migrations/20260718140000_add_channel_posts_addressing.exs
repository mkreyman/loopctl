defmodule Loopctl.Repo.Migrations.AddChannelPostsAddressing do
  use Ecto.Migration

  # US-40.A5: optional ADVISORY addressing on channel_posts so a post can label
  # its intended target (a host or, primarily, a capability) — e.g.
  # "beelink -> mac-mini because it has the fly auth capability". A later story
  # (40.C1, directed discovery) reads these columns to surface "directed-to-me"
  # posts.
  #
  # Both columns are CLIENT-SUPPLIED and SPOOFABLE — SURFACING-ONLY read hints,
  # NEVER authorization, ownership, or a delivery guarantee. They gate NOTHING
  # (mirroring the `session_id`/`host` advisory framing in the original create
  # migration, 20260717020000_create_channel_posts:18-22). The ONLY authorization
  # boundary remains the verified key's tenant + explicit tenant_id filter. Both
  # are nullable and backward-compatible: NULL on existing rows, and a post with
  # no addressing remains a broadcast visible to everyone on the channel.

  def up do
    alter table(:channel_posts) do
      add :to_host, :text, null: true
      add :to_capability, :text, null: true
    end

    # Partial indexes serve 40.C1's directed read
    # (to_host = $me OR to_capability IN $caps): only addressed rows are indexed.
    create index(:channel_posts, [:tenant_id, :project_id, :to_capability],
             where: "to_capability IS NOT NULL",
             name: :channel_posts_to_capability_idx
           )

    create index(:channel_posts, [:tenant_id, :project_id, :to_host],
             where: "to_host IS NOT NULL",
             name: :channel_posts_to_host_idx
           )
  end

  def down do
    drop index(:channel_posts, [:tenant_id, :project_id, :to_host],
           name: :channel_posts_to_host_idx
         )

    drop index(:channel_posts, [:tenant_id, :project_id, :to_capability],
           name: :channel_posts_to_capability_idx
         )

    alter table(:channel_posts) do
      remove :to_capability
      remove :to_host
    end
  end
end
