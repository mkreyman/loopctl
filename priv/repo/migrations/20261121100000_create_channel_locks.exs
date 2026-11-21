defmodule Loopctl.Repo.Migrations.CreateChannelLocks do
  @moduledoc """
  US-52.21: advisory file soft-locks move out of `channel_posts` into `channel_locks`.

  Until now a soft-lock was a `channel_posts` row under the reserved `claim:<target>` key
  with a TTL clamped to at most 3600 s. Release 4 turns `channel_posts` into the message
  store (US-52.22), where every row is a message with one attachment, so the locks move to
  a table of their own first.

  `up/0`:

    1. creates `channel_locks` (RLS ENABLED, not FORCE: the production role owns the table
       without BYPASSRLS) with the slot index `channel_locks_slot_uidx`;
    2. copies every LIVE `claim:`-keyed post (`copy_live_locks_sql/0`): unexpired, not
       quarantined, not superseded, and inside the 3600 s lock ceiling
       (`expires_at <= updated_at + 3600 s`, which a legacy 30-day `claim:` post or a
       released quarantine never satisfies). Each copy gets a fresh id and conflicts on the
       slot index `channel_locks_slot_uidx` with DO NOTHING, so a re-run inserts nothing.
       A post whose body is the default lock text copies with a NULL note;
    3. deletes every `claim:`-keyed post (`delete_claim_posts_sql/0`), live or not: the
       live ones were copied, and the rest were never live locks;
    4. drops `channel_posts_soft_lock_idx`, which only served the old lock read.

  `down/0` recreates the index and drops the table. The locks it held are not written back
  to `channel_posts`: a lock lives at most an hour, and a session re-takes its lock on its
  next refresh.
  """

  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  @doc "The copy step (2 above), kept public so its re-run behaviour is testable."
  def copy_live_locks_sql do
    """
    INSERT INTO channel_locks
      (id, tenant_id, project_id, agent_id, session_id, host, target, note, expires_at,
       inserted_at, updated_at)
    SELECT gen_random_uuid(), p.tenant_id, p.project_id, p.agent_id, p.session_id, p.host,
           substring(p.key FROM 7),
           CASE
             WHEN p.body LIKE 'advisory soft-lock: editing %' THEN NULL
             ELSE p.body
           END,
           p.expires_at, p.inserted_at, p.updated_at
    FROM channel_posts p
    WHERE p.key LIKE 'claim:%'
      AND length(p.key) > 6
      AND p.session_id IS NOT NULL
      AND p.expires_at > now()
      AND p.quarantined_at IS NULL
      AND p.superseded_by IS NULL
      AND p.expires_at <= p.updated_at + interval '3600 seconds'
    ON CONFLICT (tenant_id, project_id, agent_id, session_id, target) DO NOTHING
    """
  end

  @doc "The delete step (3 above)."
  def delete_claim_posts_sql do
    "DELETE FROM channel_posts WHERE key LIKE 'claim:%'"
  end

  def up do
    create table(:channel_locks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      # Client-supplied and spoofable; part of the slot, never authorization.
      add :session_id, :text, null: false
      add :host, :text
      add :target, :text, null: false
      add :note, :text
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :channel_locks,
             [:tenant_id, :project_id, :agent_id, :session_id, :target],
             name: :channel_locks_slot_uidx
           )

    # The pinned live-lock read: tenant + project, newest first.
    create index(:channel_locks, [:tenant_id, :project_id, "inserted_at DESC"],
             name: :channel_locks_read_idx
           )

    # The sweep (`ChannelPostSweeper`): DELETE ... WHERE expires_at < now().
    create index(:channel_locks, [:expires_at])

    # Foreign-key cascades from a deleted project or agent.
    create index(:channel_locks, [:project_id])
    create index(:channel_locks, [:agent_id])

    enable_rls(:channel_locks)

    execute(copy_live_locks_sql())
    execute(delete_claim_posts_sql())

    drop_if_exists index(:channel_posts, [], name: :channel_posts_soft_lock_idx)
  end

  def down do
    create_if_not_exists index(
                           :channel_posts,
                           [:tenant_id, :project_id, "inserted_at DESC", "seq DESC"],
                           where: "key LIKE 'claim:%'",
                           name: :channel_posts_soft_lock_idx
                         )

    drop table(:channel_locks)
  end
end
