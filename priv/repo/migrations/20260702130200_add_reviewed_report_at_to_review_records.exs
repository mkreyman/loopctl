defmodule Loopctl.Repo.Migrations.AddReviewedReportAtToReviewRecords do
  @moduledoc """
  Chain-of-custody INVARIANT 2: bind a review record to the specific REPORT
  GENERATION it reviewed. Previously `ensure_review_conducted` only checked
  `review.completed_at > story.reported_done_at` (a pure timestamp check bounded
  by a 60s skew allowance). That leaves a residual stale-review window: a review
  of an OLD report generation, if it completes after the story is re-reported,
  can still satisfy verify even though it never looked at the current report.

  `reviewed_report_at` snapshots the story's `reported_done_at` at review-record
  CREATION time (set programmatically, never cast from client input). At verify
  time the review must have `reviewed_report_at = story.reported_done_at` (i.e. it
  reviewed THIS generation); if the story was re-reported since, the snapshot no
  longer matches and a fresh review is required.

  Nullable for backwards compatibility.

  LEGACY DECISION — GRANDFATHER NULLS (not backfill): pre-migration review_records
  have `reviewed_report_at IS NULL`. The verify-time check treats `NULL` as
  "matches" (see `Loopctl.Progress.validate_review_record_exists/3`), and the
  existing `completed_at > reported_done_at` secondary guard still applies to them.
  Backfilling `reviewed_report_at = reported_done_at` was considered and REJECTED
  as ambiguous: a legacy review that reviewed an older generation but completed
  after a re-report would be fabricated as "matching the current generation",
  silently validating exactly the stale review this invariant is meant to catch.
  A NULL is an honest "unknown pre-migration generation". dev/test both have 0
  review_records, so this only affects hypothetical production legacy rows, for
  which the secondary timestamp guard remains in force.
  """
  use Ecto.Migration

  def change do
    alter table(:review_records) do
      add :reviewed_report_at, :utc_datetime_usec
    end
  end
end
