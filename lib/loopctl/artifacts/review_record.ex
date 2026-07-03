defmodule Loopctl.Artifacts.ReviewRecord do
  @moduledoc """
  Schema for the `review_records` table.

  Review records are written by the review pipeline to prove that an independent
  review was completed before a story was verified. The `verify_story/4` function
  checks for the existence of a valid review record (completed after reported_done_at)
  before allowing verification to proceed.

  ## Fields

  - `story_id` -- FK to stories table
  - `reviewer_agent_id` -- FK to agents table (the reviewing agent, nullable)
  - `review_type` -- type of review conducted (e.g. "enhanced", "team", "adversarial")
  - `findings_count` -- number of issues found during review
  - `fixes_count` -- number of issues that were fixed
  - `summary` -- human-readable summary of review findings
  - `completed_at` -- when the review pipeline completed (must be AFTER reported_done_at)
  - `reviewed_report_at` -- snapshot of the story's `reported_done_at` at the time
    this review was created. Binds the review to the specific report generation it
    reviewed (chain-of-custody INVARIANT 2). `verify_story/4` / `bulk_verify`
    require this to equal the story's CURRENT `reported_done_at`, so a review of a
    superseded report no longer qualifies. Set programmatically, never cast.
    Nullable: legacy pre-migration records are `NULL` and grandfathered as
    "matches".
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :reviewer_agent_id,
             :review_type,
             :findings_count,
             :fixes_count,
             :disproved_count,
             :summary,
             :completed_at,
             :reviewed_report_at,
             :inserted_at,
             :updated_at
           ]}

  schema "review_records" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :reviewer_agent, Loopctl.Agents.Agent

    field :review_type, :string
    field :findings_count, :integer, default: 0
    field :fixes_count, :integer, default: 0
    field :disproved_count, :integer, default: 0
    field :summary, :string
    field :completed_at, :utc_datetime_usec

    # Snapshot of story.reported_done_at at review creation (INVARIANT 2).
    # Set programmatically in Loopctl.Progress.record_review/4 — NOT in cast.
    field :reviewed_report_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new review record.

  The `tenant_id`, `story_id`, and `reviewer_agent_id` are set
  programmatically, not via cast.

  Validates that `completed_at` is not more than 60 seconds in the future (a
  clock-skew allowance), so a client cannot forward-date a review to satisfy the
  verify-time review-record check (`Loopctl.Progress.ensure_review_conducted/3`)
  for a report that had not yet happened. This `completed_at` skew check remains
  as a SECONDARY guard; the primary structural closure of the
  stale-review-vs-re-report window is `reviewed_report_at` (INVARIANT 2), which
  binds each review to the exact report generation it covers.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(record \\ %__MODULE__{}, attrs) do
    record
    |> cast(attrs, [
      :review_type,
      :findings_count,
      :fixes_count,
      :disproved_count,
      :summary,
      :completed_at
    ])
    |> validate_required([:review_type, :completed_at])
    |> validate_length(:review_type, min: 1)
    # Bound the summary length (Epic 28, #179 review). The summary is fed verbatim
    # into the BYO review-knowledge LLM extraction, so an unbounded summary is an
    # unbounded per-call token (cost) surface. 16k chars is generous for a real
    # review summary while capping the extraction input.
    |> validate_length(:summary, max: 16_000)
    |> validate_number(:findings_count, greater_than_or_equal_to: 0)
    |> validate_number(:fixes_count, greater_than_or_equal_to: 0)
    |> validate_number(:disproved_count, greater_than_or_equal_to: 0)
    |> validate_completed_at_not_future()
    |> validate_findings_math()
  end

  # Validates that completed_at is not more than 60 seconds in the future
  # (clock-skew allowance only — a review does not legitimately "complete" in
  # the future).
  @completed_at_future_skew_seconds 60

  defp validate_completed_at_not_future(changeset) do
    case Ecto.Changeset.get_field(changeset, :completed_at) do
      nil ->
        changeset

      completed_at ->
        max_future =
          DateTime.utc_now() |> DateTime.add(@completed_at_future_skew_seconds, :second)

        if DateTime.compare(completed_at, max_future) == :gt do
          Ecto.Changeset.add_error(
            changeset,
            :completed_at,
            "cannot be more than #{@completed_at_future_skew_seconds} seconds in the future"
          )
        else
          changeset
        end
    end
  end

  defp validate_findings_math(changeset) do
    findings = Ecto.Changeset.get_field(changeset, :findings_count) || 0
    fixes = Ecto.Changeset.get_field(changeset, :fixes_count) || 0
    disproved = Ecto.Changeset.get_field(changeset, :disproved_count) || 0

    accounted = fixes + disproved

    cond do
      findings == 0 ->
        changeset

      accounted < findings ->
        Ecto.Changeset.add_error(
          changeset,
          :fixes_count,
          "#{findings} findings confirmed but only #{fixes} fixed and #{disproved} disproved. " <>
            "All findings must be either fixed or explicitly disproved. " <>
            "#{findings - accounted} findings unaccounted for."
        )

      true ->
        changeset
    end
  end
end
