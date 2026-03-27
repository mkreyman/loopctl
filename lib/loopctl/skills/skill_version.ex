defmodule Loopctl.Skills.SkillVersion do
  @moduledoc """
  Schema for the `skill_versions` table.

  Skill versions are immutable snapshots of skill prompt text. Each prompt
  change creates a new version with an auto-incremented version number.

  ## Fields

  - `version` -- 1-indexed, auto-incremented per skill
  - `prompt_text` -- the full skill prompt/instructions
  - `changelog` -- what changed from previous version
  - `created_by` -- actor label (agent name, "user", etc.)
  - `metadata` -- extensible JSONB
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "skill_versions" do
    tenant_field()
    belongs_to :skill, Loopctl.Skills.Skill

    field :version, :integer
    field :prompt_text, :string
    field :changelog, :string
    field :created_by, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new skill version.

  `tenant_id`, `skill_id`, and `version` are set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(version \\ %__MODULE__{}, attrs) do
    version
    |> cast(attrs, [:prompt_text, :changelog, :created_by, :metadata])
    |> validate_required([:prompt_text])
    |> unique_constraint([:skill_id, :version])
  end
end
