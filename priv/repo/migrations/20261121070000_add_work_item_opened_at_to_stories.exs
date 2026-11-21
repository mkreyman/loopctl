defmodule Loopctl.Repo.Migrations.AddWorkItemOpenedAtToStories do
  @moduledoc """
  A story opened as an interactive work item (US-52.18) says so, and implement@1 never places
  one.

  When a holder ends, its uncapped claims are released through `unclaim`, which moves the
  item's stage back to `queued` so the session that re-registers can take its branch's item
  back. implement@1 read every `queued` authored story as a candidate, so the factory placed
  the session's own branch on a runner: in production on 2026-11-21 four items (one per ended
  session) were claimed and dispatched, and each session escalated a story with no
  description and no acceptance criteria.

  `stories.work_item_opened_at` is stamped by `Loopctl.WorkItems.Open` when it creates the
  item and never cast (`metadata` is whole-map-replaced by a PATCH, so a marker there could be
  erased by one request). `Loopctl.Agents.Candidates`' `:not_work_item` reads it.

  The backfill reads the item event log: the open's `claimed` event carries the reason
  "interactive work started on <branch>" (`Loopctl.WorkItems.Open.reason/1`). The table has
  RLS ENABLED, not FORCED, so the owning role reads every tenant's rows. `audit_log` FORCES
  RLS and would answer nothing here.
  """

  use Ecto.Migration

  def up do
    alter table(:stories) do
      add :work_item_opened_at, :utc_datetime_usec
    end

    execute("""
    UPDATE stories s
       SET work_item_opened_at = e.opened_at
      FROM (
        SELECT tenant_id, story_id, min(inserted_at) AS opened_at
          FROM story_stage_events
         WHERE event = 'claimed' AND reason LIKE 'interactive work started on %'
         GROUP BY tenant_id, story_id
      ) e
     WHERE s.tenant_id = e.tenant_id AND s.id = e.story_id
    """)
  end

  def down do
    alter table(:stories) do
      remove :work_item_opened_at
    end
  end
end
