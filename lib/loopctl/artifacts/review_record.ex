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
             :summary,
             :completed_at,
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
    field :summary, :string
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new review record.

  The `tenant_id`, `story_id`, and `reviewer_agent_id` are set
  programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(record \\ %__MODULE__{}, attrs) do
    record
    |> cast(attrs, [:review_type, :findings_count, :fixes_count, :summary, :completed_at])
    |> validate_required([:review_type, :completed_at])
    |> validate_length(:review_type, min: 1)
    |> validate_number(:findings_count, greater_than_or_equal_to: 0)
    |> validate_number(:fixes_count, greater_than_or_equal_to: 0)
  end
end
