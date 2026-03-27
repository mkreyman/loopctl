defmodule Loopctl.WorkBreakdown.Epic do
  @moduledoc """
  Schema for the `epics` table.

  Epics are the intermediate grouping between projects and stories. They
  represent feature areas or phases of development (e.g., "Foundation",
  "Authentication", "Work Breakdown").

  ## Fields

  - `number` -- integer, unique within a project (stable human-readable ID)
  - `title` -- display name
  - `description` -- freeform text description
  - `phase` -- free-form string for grouping by development phase
  - `position` -- integer for custom ordering within a phase (default 0)
  - `metadata` -- JSONB map for extensibility
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :number,
             :title,
             :description,
             :phase,
             :position,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "epics" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project
    field :number, :integer
    field :title, :string
    field :description, :string
    field :phase, :string
    field :position, :integer, default: 0
    field :metadata, :map, default: %{}

    has_many :stories, Loopctl.WorkBreakdown.Story

    timestamps()
  end

  @doc """
  Changeset for creating a new epic.

  The `tenant_id` and `project_id` are set programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(epic \\ %__MODULE__{}, attrs) do
    epic
    |> cast(attrs, [:number, :title, :description, :phase, :position, :metadata])
    |> validate_required([:number, :title])
    |> validate_number(:number, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :project_id, :number],
      message: "has already been taken for this project"
    )
  end

  @doc """
  Changeset for updating an existing epic.

  Number cannot be changed after creation.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(epic, attrs) do
    epic
    |> cast(attrs, [:title, :description, :phase, :position, :metadata])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_metadata()
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end
end
