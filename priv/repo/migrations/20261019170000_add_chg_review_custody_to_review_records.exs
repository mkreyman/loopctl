defmodule Loopctl.Repo.Migrations.AddChgReviewCustodyToReviewRecords do
  @moduledoc """
  US-47.5: review custody for chg-dispatched reviews (Epic 47 PRD §6).

  - `review_records.commit_sha` — the revision commit a chg reviewer reviewed: the envelope
    `sha` of a `submitted` event of the story's current change binding. Required for a story
    bound to a chg change and never written for any other (`Loopctl.Progress.record_review/4`),
    so a verdict on revision 1 is never read as covering revision 2, and a review recorded
    BEFORE the story was bound never counts as a chg review.
  - `review_records.reviewer_dispatch_id` — the chg reviewer's own dispatch (the leaf of its
    server-resolved lineage). Written for the same reviews and no others.
  - `review_records_reviewer_dispatch_uidx` — ONE VERDICT PER REVIEWER DISPATCH, held by the
    database rather than by a read-then-write: chg mints one child dispatch per
    `(change_id, revision)` review, so a second verdict from the same key is a retry or a
    replay, never a second review. Unique on the dispatch id alone (dispatch ids are global
    UUIDs, so it is the same rule as `(tenant_id, reviewer_dispatch_id)`), which also serves the
    referential check a dispatch delete runs (`20260928140000_index_foreign_keys_into_dispatches`).
  - `review_records_chg_review_shape` — the two columns are set together or not at all.

  Additive: two nullable columns, a CHECK every existing row satisfies (both NULL) and a
  partial index over no rows yet, so the code running before this release keeps working
  against the new schema during Fly's rolling deploy. `review_records` is small (one row per
  review), so the index is built in the migration's transaction.

  The reference to `dispatches` is single-column and `ON DELETE NO ACTION`, like every other
  one (`20261019140000_add_chg_mode_to_intake_sources` says why).
  """

  use Ecto.Migration

  @sha "'^[0-9a-f]{40}([0-9a-f]{24})?$'"

  def up do
    alter table(:review_records) do
      add :commit_sha, :text, null: true
      add :reviewer_dispatch_id, references(:dispatches, type: :binary_id, on_delete: :nothing)
    end

    create constraint(:review_records, :review_records_commit_sha, check: "commit_sha ~ #{@sha}")

    create constraint(:review_records, :review_records_chg_review_shape,
             check: "(commit_sha IS NULL) = (reviewer_dispatch_id IS NULL)"
           )

    create unique_index(:review_records, [:reviewer_dispatch_id],
             where: "reviewer_dispatch_id IS NOT NULL",
             name: :review_records_reviewer_dispatch_uidx
           )
  end

  def down do
    drop index(:review_records, [:reviewer_dispatch_id],
           name: :review_records_reviewer_dispatch_uidx
         )

    drop constraint(:review_records, :review_records_chg_review_shape)
    drop constraint(:review_records, :review_records_commit_sha)

    alter table(:review_records) do
      remove :reviewer_dispatch_id
      remove :commit_sha
    end
  end
end
