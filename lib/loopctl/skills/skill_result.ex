defmodule Loopctl.Skills.SkillResult do
  @moduledoc """
  Schema for the `skill_results` table.

  Links verification results to the skill version that produced them,
  enabling performance comparison across versions.

  ## Fields

  - `skill_version_id` -- FK to skill_versions
  - `verification_result_id` -- FK to verification_results
  - `story_id` -- FK to stories
  - `metrics` -- JSONB with findings_count, false_positive_count, etc.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "skill_results" do
    tenant_field()
    belongs_to :skill_version, Loopctl.Skills.SkillVersion
    belongs_to :verification_result, Loopctl.Artifacts.VerificationResult
    belongs_to :story, Loopctl.WorkBreakdown.Story

    field :metrics, :map, default: %{}

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new skill result.

  `tenant_id`, `skill_version_id`, `verification_result_id`, and `story_id`
  are set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(result \\ %__MODULE__{}, attrs) do
    result
    |> cast(attrs, [:metrics])
    |> validate_required([:skill_version_id, :verification_result_id, :story_id])
    |> foreign_key_constraint(:skill_version_id)
    |> foreign_key_constraint(:verification_result_id)
    |> foreign_key_constraint(:story_id)
  end
end
