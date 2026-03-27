defmodule Loopctl.Artifacts.VerificationResult do
  @moduledoc """
  Schema for the `verification_results` table.

  Verification results record the orchestrator's independent assessment of a
  story. Each verify/reject creates a new immutable record, building a history
  of verification attempts.

  ## Fields

  - `orchestrator_agent_id` -- FK to agents table (the verifier)
  - `result` -- enum: pass, fail, partial
  - `summary` -- human-readable summary of the verification
  - `findings` -- JSONB map for structured findings
  - `review_type` -- free-form string (e.g., "enhanced_review", "artifact_check")
  - `iteration` -- 1-indexed attempt number for this story
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @result_values [:pass, :fail, :partial]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :orchestrator_agent_id,
             :result,
             :summary,
             :findings,
             :review_type,
             :iteration,
             :inserted_at,
             :updated_at
           ]}

  schema "verification_results" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :orchestrator_agent, Loopctl.Agents.Agent

    field :result, Ecto.Enum, values: @result_values
    field :summary, :string
    field :findings, :map, default: %{}
    field :review_type, :string
    field :iteration, :integer, default: 1

    timestamps()
  end

  @doc """
  Changeset for creating a new verification result.

  The `tenant_id`, `story_id`, and `orchestrator_agent_id` are set
  programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(result \\ %__MODULE__{}, attrs) do
    result
    |> cast(attrs, [:result, :summary, :findings, :review_type, :iteration])
    |> validate_required([:result])
    |> validate_inclusion(:result, @result_values)
  end
end
