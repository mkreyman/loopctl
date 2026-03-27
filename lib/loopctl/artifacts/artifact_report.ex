defmodule Loopctl.Artifacts.ArtifactReport do
  @moduledoc """
  Schema for the `artifact_reports` table.

  Artifact reports record what an agent or orchestrator found after a story
  was implemented. Each report tracks a specific artifact (file, migration,
  test, commit diff, etc.) and whether it exists.

  ## Fields

  - `reported_by` -- enum: agent, orchestrator
  - `reporter_agent_id` -- FK to agents table
  - `artifact_type` -- free-form string (e.g., "migration", "schema", "commit_diff")
  - `path` -- file path or git ref
  - `exists` -- boolean indicating artifact existence
  - `details` -- JSONB map for flexible additional data
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @reported_by_values [:agent, :orchestrator]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :reported_by,
             :reporter_agent_id,
             :artifact_type,
             :path,
             :exists,
             :details,
             :inserted_at,
             :updated_at
           ]}

  schema "artifact_reports" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :reporter_agent, Loopctl.Agents.Agent

    field :reported_by, Ecto.Enum, values: @reported_by_values
    field :artifact_type, :string
    field :path, :string
    field :exists, :boolean, default: true
    field :details, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for creating a new artifact report.

  The `tenant_id`, `story_id`, `reported_by`, and `reporter_agent_id` are
  set programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, [:artifact_type, :path, :exists, :details])
    |> validate_required([:artifact_type, :path])
  end
end
