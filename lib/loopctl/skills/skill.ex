defmodule Loopctl.Skills.Skill do
  @moduledoc """
  Schema for the `skills` table.

  Skills are versioned orchestrator prompts, review instructions, or agent
  skill definitions. Each skill has a name unique within a tenant, and
  tracks a `current_version` pointer to the latest skill_version.

  ## Fields

  - `name` -- namespaced identifier (e.g., "loopctl:review")
  - `description` -- what this skill does
  - `current_version` -- integer pointing to the latest version number
  - `status` -- enum: active, archived
  - `project_id` -- optional FK to projects (null = tenant-wide)
  - `metadata` -- extensible JSONB
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @status_values [:active, :archived]

  schema "skills" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    field :name, :string
    field :description, :string
    field :current_version, :integer, default: 1
    field :status, Ecto.Enum, values: @status_values, default: :active
    field :metadata, :map, default: %{}

    has_many :versions, Loopctl.Skills.SkillVersion

    timestamps()
  end

  @doc """
  Changeset for creating a new skill.

  `tenant_id` and `project_id` are set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(skill \\ %__MODULE__{}, attrs) do
    skill
    |> cast(attrs, [:name, :description, :metadata])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:tenant_id, :name],
      name: :skills_tenant_project_name_index,
      message: "has already been taken for this tenant and project"
    )
  end

  @doc """
  Changeset for updating skill metadata (NOT prompt text -- that's a new version).
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(skill, attrs) do
    skill
    |> cast(attrs, [:description, :status, :metadata])
    |> validate_inclusion(:status, @status_values)
  end
end
