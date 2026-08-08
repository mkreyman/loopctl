defmodule Loopctl.Repo.Migrations.AddLifecycleEnteredAtToStories do
  use Ecto.Migration

  @moduledoc """
  Moves the backfill anti-launder marker off `stories.metadata` and onto a column
  of its own.

  The marker records that a story ENTERED the dispatch lifecycle, and it is
  stamped by the three paths that clear `assigned_agent_id` on a worked story
  (unclaim, force-unclaim, reject auto-reset). `Progress.guard_backfillable/2`
  refuses to certify a story that carries it — that is what stops a claim ->
  force-unclaim -> backfill-to-verified launder.

  On `metadata` the marker was client-erasable: `Story.update_changeset/2` casts
  `:metadata` and `PATCH /api/v1/stories/:id` REPLACES the whole map, so one
  ordinary request restored the launder path. A column that no changeset casts
  cannot be written by any request body.

  The backfill below carries the markers stamped while they still lived in
  `metadata` onto the new column, so stories already marked stay marked even if
  their metadata is later replaced. A forged metadata stamp only makes backfill
  refuse a story it would otherwise certify, so trusting it here loses nothing.
  """

  def up do
    alter table(:stories) do
      add :lifecycle_entered_at, :utc_datetime_usec
    end

    # Only PRESENCE is read by the guard, so the stamped instant is taken from
    # `updated_at` rather than parsed out of the JSON — a client could have written
    # any string there, and a cast that raises would fail the whole migration.
    execute("""
    UPDATE stories
       SET lifecycle_entered_at = updated_at
     WHERE metadata->>'lifecycle_entered_at' IS NOT NULL
       AND lifecycle_entered_at IS NULL
    """)
  end

  def down do
    alter table(:stories) do
      remove :lifecycle_entered_at
    end
  end
end
