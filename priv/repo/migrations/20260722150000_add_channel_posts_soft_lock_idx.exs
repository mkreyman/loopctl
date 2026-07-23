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
  # The reads MUST spell the predicate as a SQL LITERAL (`key LIKE 'claim:%'`), never
  # as a bind parameter: Postgres only uses a partial index when it can PROVE the
  # query predicate implies the index predicate, and that proof is Const-based — it
  # cannot reason about a Param node, so `key LIKE $1` never matches this index.
  # `Loopctl.Coordination.@lock_key_like` is that literal (review #451).
  #
  # This is the same left-anchored-prefix + partial-index approach US-40.C1 uses for
  # handoff discovery (20260719160000_add_channel_posts_handoff_discovery_idx), and
  # the reason the story explicitly rejects adding a `kind` column: the key prefix IS
  # the routing signal. `create index/2` is reversible, so `change` is sufficient.

  # `create_if_not_exists` (rather than `create`): this migration was renamed from
  # 20260722120000 during review #451 so it sorts AFTER the three 20260722140000-series
  # migrations already on master — a database that ran the pre-rename version would
  # otherwise fail here with `42P07 duplicate_table`. Still reversible, so `change`
  # remains sufficient.
  def change do
    create_if_not_exists index(
                           :channel_posts,
                           [:tenant_id, :project_id, "inserted_at DESC", "seq DESC"],
                           where: "key LIKE 'claim:%'",
                           name: :channel_posts_soft_lock_idx
                         )
  end
end
