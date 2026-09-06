defmodule Loopctl.Repo.Migrations.AddReferencedToRetrievalSnapshots do
  use Ecto.Migration

  @moduledoc """
  Adds the third funnel stage to the daily retrieval snapshot.

  The series has measured two stages since #582: how many results a search SURFACED, and
  how many of those the agent then OPENED. Whether an opened article was actually USED was
  never recorded, and that is the stage the follow-through deficit is about — surfaced to
  opened converted at 1.67%, and nothing said what happened after an open.

  `POST /api/v1/recall/:recall_id/referenced` now records it as an
  `article_access_events` row of type `referenced`, and this column counts them per day.

  Two properties of the counter, both deliberate:

    * it counts DISTINCT `(origin_search_id, article_id)` pairs, so a client that posts
      the same reference twice cannot move the number;
    * a `referenced` row is in NO read set — not the heat index, not `@read_access_types`,
      not the live metrics' chosen reads. It is the one access type a CLIENT asserts about
      itself, and a ranking that consumed it would be ranking on self-report.

  `reference_rate` is NOT a column: it is `referenced / searched`, both stored here, so it
  is derived at presentation time and is therefore correct for every historical row without
  a backfill — the same treatment `scored_follow_through` gets, and for the same reason
  (two sources for one number is how a published figure and a stored one drift).

  Defaults to 0 so historical snapshots stay readable. Rows written before this migration
  report a genuine zero: the endpoint did not exist, so nothing was referenced. That is why
  this is not an `n/a` the way `searches_scored = 0` is — but the metric version bump
  (v1 to v2) still marks the boundary, because a reader comparing `reference_rate` across
  it is comparing a stage that could not be recorded with one that could.
  """

  def change do
    alter table(:retrieval_metric_snapshots) do
      add :referenced, :integer, default: 0, null: false
    end
  end
end
