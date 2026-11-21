defmodule Loopctl.Repo.Migrations.ChannelPostsAttachments do
  @moduledoc """
  US-52.22: a channel post becomes a message with exactly one attachment.

  A row is attached to a work item's thread (`story_id`, with the story's `project_id`), to one
  holder's DMs (`to_holder_id` alone), or to a repo channel (`project_id` alone); the check
  `channel_posts_one_attachment` admits those three shapes and no other. Each attachment numbers
  its own messages in `attachment_seq`, unique per `(tenant_id, attachment)` under
  `channel_posts_attachment_seq_uidx`, and `Loopctl.Coordination.Messages.insert/2` assigns it
  under an advisory lock on the attachment, so the order of `attachment_seq` is commit order.

  `up/0`:

    1. adds `story_id` (cascade with the story), `to_holder_id` (cascade with the holder),
       `author_holder_id` (nulled with the holder) and `attachment_seq`; `project_id` and
       `expires_at` become nullable (a DM has no project, and a thread or DM never ages out);
    2. backfills `attachment_seq` 1..n per project in `(inserted_at, seq)` order
       (`backfill_attachment_seq_sql/1`);
    3. clamps every channel row whose key does not start `handoff:` to the new 7-day window,
       `LEAST(expires_at, inserted_at + 7 days)` (`clamp_retention_sql/1`). A QUARANTINED row is
       left alone: its `expires_at` is the operator's review window (issue #499), and clamping
       it would delete the only evidence behind an open `:secret_detected` alert;
    4. folds the retired keyed working-state slots (`fold_keyed_slots_sql/1`): the escalation
       digest's day key moves into `idempotency_key`, which is what dedups it from now on, and
       every key that does not start `handoff:` becomes NULL;
    5. rebuilds `channel_posts_session_key_uidx` with the predicate `key LIKE 'handoff:%'`;
    6. makes `attachment_seq` NOT NULL and adds its unique index, the check, and the indexes the
       two holder foreign keys and the story foreign key cascade through.

  The table is small (30-day TTL), so the index rebuild runs in the migration's transaction,
  without CONCURRENTLY.

  `down/0` deletes thread and DM rows (they cannot exist in the old shape), restores the old
  slot index and the NOT NULL columns, and drops the new columns. Folded keys are not restored.
  """

  use Ecto.Migration

  @doc "Step 2. `scope` narrows the rows (a test passes a tenant predicate); empty = all rows."
  def backfill_attachment_seq_sql(scope \\ "") do
    """
    UPDATE channel_posts p
    SET attachment_seq = r.n
    FROM (
      SELECT id,
             row_number() OVER (PARTITION BY tenant_id, project_id ORDER BY inserted_at, seq) AS n
      FROM channel_posts
      WHERE TRUE #{scope}
    ) r
    WHERE p.id = r.id
    """
  end

  @doc "Step 3."
  def clamp_retention_sql(scope \\ "") do
    """
    UPDATE channel_posts
    SET expires_at = LEAST(expires_at, inserted_at + interval '7 days')
    WHERE (key IS NULL OR key NOT LIKE 'handoff:%')
      AND quarantined_at IS NULL
      #{scope}
    """
  end

  @doc "Step 4: the digest's key becomes its idempotency key, then every non-handoff key goes."
  def fold_keyed_slots_sql(scope \\ "") do
    [
      """
      UPDATE channel_posts
      SET idempotency_key = key
      WHERE key LIKE 'escalation-digest:%' AND idempotency_key IS NULL
        #{scope}
      """,
      """
      UPDATE channel_posts
      SET key = NULL
      WHERE key IS NOT NULL AND key NOT LIKE 'handoff:%'
        #{scope}
      """
    ]
  end

  def up do
    alter table(:channel_posts) do
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all)
      add :to_holder_id, references(:holders, type: :binary_id, on_delete: :delete_all)
      add :author_holder_id, references(:holders, type: :binary_id, on_delete: :nilify_all)
      add :attachment_seq, :bigint
    end

    execute("ALTER TABLE channel_posts ALTER COLUMN project_id DROP NOT NULL")
    execute("ALTER TABLE channel_posts ALTER COLUMN expires_at DROP NOT NULL")

    execute(backfill_attachment_seq_sql())
    execute(clamp_retention_sql())
    Enum.each(fold_keyed_slots_sql(), &execute/1)

    drop index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
           name: :channel_posts_session_key_uidx
         )

    create unique_index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
             where: "key LIKE 'handoff:%'",
             name: :channel_posts_session_key_uidx
           )

    execute("ALTER TABLE channel_posts ALTER COLUMN attachment_seq SET NOT NULL")

    create unique_index(
             :channel_posts,
             [:tenant_id, "COALESCE(story_id, to_holder_id, project_id)", :attachment_seq],
             name: :channel_posts_attachment_seq_uidx
           )

    create constraint(:channel_posts, :channel_posts_one_attachment,
             check: """
             (story_id IS NOT NULL AND project_id IS NOT NULL AND to_holder_id IS NULL)
             OR (to_holder_id IS NOT NULL AND story_id IS NULL AND project_id IS NULL)
             OR (project_id IS NOT NULL AND story_id IS NULL AND to_holder_id IS NULL)
             """
           )

    create index(:channel_posts, [:story_id], where: "story_id IS NOT NULL")
    create index(:channel_posts, [:to_holder_id], where: "to_holder_id IS NOT NULL")
    create index(:channel_posts, [:author_holder_id], where: "author_holder_id IS NOT NULL")
  end

  def down do
    execute("DELETE FROM channel_posts WHERE story_id IS NOT NULL OR to_holder_id IS NOT NULL")

    drop constraint(:channel_posts, :channel_posts_one_attachment)
    drop index(:channel_posts, [], name: :channel_posts_attachment_seq_uidx)

    drop index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
           name: :channel_posts_session_key_uidx
         )

    create unique_index(:channel_posts, [:tenant_id, :project_id, :agent_id, :session_id, :key],
             where: "key IS NOT NULL",
             name: :channel_posts_session_key_uidx
           )

    alter table(:channel_posts) do
      remove :story_id
      remove :to_holder_id
      remove :author_holder_id
      remove :attachment_seq
    end

    execute("ALTER TABLE channel_posts ALTER COLUMN project_id SET NOT NULL")
    execute("ALTER TABLE channel_posts ALTER COLUMN expires_at SET NOT NULL")
  end
end
