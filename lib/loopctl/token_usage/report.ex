defmodule Loopctl.TokenUsage.Report do
  @moduledoc """
  Schema for the `token_usage_reports` table.

  Tracks token consumption and cost for agent work on stories.
  Each report records input/output tokens, the model used, and cost
  in millicents (1/1000 of a cent).

  ## Fields

  - `input_tokens` -- number of input tokens consumed
  - `output_tokens` -- number of output tokens consumed
  - `total_tokens` -- generated column: input_tokens + output_tokens (read-only)
  - `model_name` -- name of the LLM model used (e.g., "claude-opus-4")
  - `cost_millicents` -- cost in 1/1000 of a cent (e.g., 2500 = $0.025)
  - `phase` -- work phase: planning, implementing, reviewing, other
  - `session_id` -- optional session identifier
  - `skill_version_id` -- optional FK to skill_versions
  - `metadata` -- extensible JSONB map
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @phases ~w(planning implementing reviewing other)

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :agent_id,
             :project_id,
             :input_tokens,
             :output_tokens,
             :total_tokens,
             :model_name,
             :cost_millicents,
             :phase,
             :session_id,
             :skill_version_id,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "token_usage_reports" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :agent, Loopctl.Agents.Agent
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :skill_version, Loopctl.Skills.SkillVersion

    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :model_name, :string
    field :cost_millicents, :integer
    field :phase, :string, default: "other"
    field :session_id, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for creating a new token usage report.

  The `tenant_id`, `agent_id`, and `project_id` are set programmatically
  and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, [
      :input_tokens,
      :output_tokens,
      :model_name,
      :cost_millicents,
      :phase,
      :session_id,
      :skill_version_id,
      :metadata
    ])
    |> validate_required([:input_tokens, :output_tokens, :model_name, :cost_millicents])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_millicents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:phase, @phases)
    |> validate_length(:model_name, min: 1)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:story_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:skill_version_id)
  end
end
