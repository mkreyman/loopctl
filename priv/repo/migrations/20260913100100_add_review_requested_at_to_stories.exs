defmodule Loopctl.Repo.Migrations.AddReviewRequestedAtToStories do
  use Ecto.Migration

  @moduledoc """
  #803 — `stories.review_requested_at`, set by `Progress.request_review/3`.

  A story waiting for review stays `implementing` until a different principal reports it,
  and only its implementer can renew the claim, so the implementer's lease stops applying
  once review is requested: `ReclaimExpiredClaimsWorker` skips a stamped story, and
  `Progress.reclaim_expired_claim/3` refuses one under the row lock. Cleared by every
  release. In no changeset `cast` list.

  A separate migration from `20260913100000` rather than an edit to it, so a database that
  already ran that version still gets the column. A nullable ADD COLUMN is catalog-only.
  `stories_claimed_until_leased_idx` is left as it is: the sweep's extra
  `review_requested_at IS NULL` filter is applied on top of the index scan.
  """

  # Explicit up/down: `add_if_not_exists` is not reversible, so inside `change/0` a
  # rollback raises instead of dropping the column.
  def up do
    alter table(:stories) do
      add_if_not_exists :review_requested_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:stories) do
      remove_if_exists :review_requested_at, :utc_datetime_usec
    end
  end
end
