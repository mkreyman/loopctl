defmodule Loopctl.Repo.Migrations.AddChannelPostsHandoffDiscoveryIdx do
  use Ecto.Migration

  # US-40.C1: partial index serving the directed-handoff discovery read
  # (`Loopctl.Coordination.directed_handoffs/3`). That query filters
  #   tenant_id = $t AND project_id = $p AND key LIKE 'handoff:%'
  # so a partial index over (tenant_id, project_id, to_host, to_capability) with
  # the SAME `key LIKE 'handoff:%'` predicate lets Postgres seek straight to a
  # tenant/project's handoff rows. Only handoff posts are indexed → the index
  # stays SMALL.
  #
  # Post-US-454: the DEFAULT read is UNFILTERED (see-everything, `only_mine:
  # false`); the index still serves the tenant/project prefix efficiently. The
  # `only_mine: true` opt-in narrows to address-matched rows, which this index
  # also serves. Precedent: 20260718140000_add_channel_posts_addressing
  # (the A5 partial addressing indexes). `create index/2` is reversible, so a
  # `change` is sufficient.

  def change do
    create index(:channel_posts, [:tenant_id, :project_id, :to_host, :to_capability],
             where: "key LIKE 'handoff:%'",
             name: :channel_posts_handoff_discovery_idx
           )
  end
end
