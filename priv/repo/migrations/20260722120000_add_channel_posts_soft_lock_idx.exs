defmodule Loopctl.Repo.Migrations.AddChannelPostsSoftLockIdx do
  use Ecto.Migration

  # US-40.4: partial index serving the advisory soft-lock read
  # (`Loopctl.Coordination.active_locks/3`). That query filters
  #   tenant_id = $t AND project_id = $p AND key LIKE 'claim:%' AND expires_at > now()
  # and orders newest-first, so a partial index over
  # (tenant_id, project_id, inserted_at DESC, seq DESC) carrying the SAME
  # `key LIKE 'claim:%'` predicate lets Postgres seek straight to a tenant/project's
  # lock rows in read order. Only soft-lock posts are indexed → the index stays TINY
  # (locks live at most 60 minutes by clamp).
  #
  # This is the same left-anchored-prefix + partial-index approach US-40.C1 uses for
  # handoff discovery (20260719160000_add_channel_posts_handoff_discovery_idx), and
  # the reason the story explicitly rejects adding a `kind` column: the key prefix IS
  # the routing signal. `create index/2` is reversible, so `change` is sufficient.

  def change do
    create index(:channel_posts, [:tenant_id, :project_id, "inserted_at DESC", "seq DESC"],
             where: "key LIKE 'claim:%'",
             name: :channel_posts_soft_lock_idx
           )
  end
end
