defmodule Loopctl.Repo.Migrations.AddLifecycleEnteredAtToStories do
  use Ecto.Migration

  # Inside one Ecto-wrapped transaction the ALTER's ACCESS EXCLUSIVE lock on `stories`
  # — the hottest table — would be held through the backfills' full unindexed scans.
  # Disabled, the catalog-only ADD COLUMN commits alone and each batch below is its own
  # statement. Same pattern as 20260702130100_add_reported_done_requires_agent_check.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  Moves the backfill anti-launder marker off `stories.metadata`, where
  `PATCH /api/v1/stories/:id` erased it by replacing the whole map, and onto a column
  no changeset casts. See `Progress.guard_no_lifecycle_history/2`.

  Two backfills, because the guard's other two sources both expire: the metadata
  markers already stamped, then every story whose `audit_log` still SHOWS lifecycle
  history — those rows are dropped at `:audit_retention_days`, so without this a story
  force-unclaimed before the column existed reads as never-dispatched once its
  partition goes. A false stamp only makes backfill refuse MORE, so trusting both
  sources loses nothing. Only PRESENCE is read, so the instant comes from `updated_at`
  rather than a client-written JSON string a cast could raise on.

  `down/0` copies the column back into `metadata` (still honoured on read) before
  dropping it — a plain drop would destroy every marker stamped since deploy.
  """

  @batch 5_000
  @actions "'status_changed','force_unclaimed','auto_reset'"

  def up do
    execute("ALTER TABLE stories ADD COLUMN IF NOT EXISTS lifecycle_entered_at timestamptz")
    # `execute/1` is queued by the runner; the batches use repo().query! and run NOW.
    flush()

    in_batches("""
    UPDATE stories SET lifecycle_entered_at = updated_at
     WHERE id IN (SELECT id FROM stories WHERE lifecycle_entered_at IS NULL
                    AND metadata->>'lifecycle_entered_at' IS NOT NULL LIMIT #{@batch})
    """)

    in_batches("""
    UPDATE stories SET lifecycle_entered_at = updated_at
     WHERE id IN (SELECT s.id FROM stories s WHERE s.lifecycle_entered_at IS NULL
                    AND EXISTS (SELECT 1 FROM audit_log a
                                 WHERE a.tenant_id = s.tenant_id AND a.entity_type = 'story'
                                   AND a.entity_id = s.id AND a.action IN (#{@actions}))
                  LIMIT #{@batch})
    """)
  end

  def down do
    in_batches("""
    UPDATE stories SET metadata = coalesce(metadata, '{}'::jsonb) ||
             jsonb_build_object('lifecycle_entered_at', lifecycle_entered_at)
     WHERE id IN (SELECT id FROM stories WHERE lifecycle_entered_at IS NOT NULL
                    AND metadata->>'lifecycle_entered_at' IS NULL LIMIT #{@batch})
    """)

    execute("ALTER TABLE stories DROP COLUMN IF EXISTS lifecycle_entered_at")
  end

  defp in_batches(sql) do
    Stream.repeatedly(fn -> repo().query!(sql, [], log: false).num_rows end)
    |> Enum.find(&(&1 < @batch))
  end
end
