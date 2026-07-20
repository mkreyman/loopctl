defmodule Loopctl.Repo.Migrations.AddIdempotencyKeyToChannelPosts do
  use Ecto.Migration

  @moduledoc """
  Adds an OPTIONAL client `idempotency_key` for idempotent KEYLESS channel writes
  (US-40.B2). A retried or offline-reconciled `/handoff` post is a pure append, so
  without a token a duplicate row lands. When a token IS supplied, a repeat write
  with the same `(tenant_id, project_id, agent_id, idempotency_key)` returns the
  EXISTING post instead of appending a duplicate — the same guarantee
  `knowledge_create` gives.

  The token is scoped to `(tenant_id, project_id, agent_id, idempotency_key)`
  (AC-40.B2.3) so one agent's token never collides with another's. The partial
  unique index allows unlimited rows with a NULL key (the default, exactly today's
  append-only behavior) while enforcing at-most-one post per
  `(tenant, project, agent, idempotency_key)` when a token is given.

  This is a SEPARATE dedup dimension from the keyed working-state slot
  (`channel_posts_session_key_uidx`, on `session_id + key`) and MUST stay
  orthogonal to it — the idempotency token is only consulted on the KEYLESS path.

  To keep that orthogonality TRUE at the storage layer, the partial index is
  scoped `WHERE idempotency_key IS NOT NULL AND key IS NULL`: the idempotency
  dimension applies to KEYLESS posts ONLY. Without the `key IS NULL` predicate a
  KEYED post that also carried a token would silently participate in the
  idempotency index, enabling out-of-scope cross-session KEYED dedup (a second
  session's distinct keyed slot write would collide on the token and be dropped)
  — the exact anti-invariant the moduledoc forbids. The application layer belts
  this: `ChannelPost.create_changeset/2` REJECTS a request carrying both `key`
  and `idempotency_key` (422), so no row ever holds both non-null; the scoped
  predicate is the defense-in-depth backstop for that contract.

  The `channel_posts` table already has RLS ENABLED (not FORCE); a column add
  needs no RLS change.
  """

  def change do
    alter table(:channel_posts) do
      add :idempotency_key, :string
    end

    create unique_index(:channel_posts, [:tenant_id, :project_id, :agent_id, :idempotency_key],
             name: :channel_posts_idempotency_uidx,
             where: "idempotency_key IS NOT NULL AND key IS NULL"
           )
  end
end
