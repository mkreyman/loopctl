defmodule Loopctl.WorkBreakdown.EpicDependency do
  @moduledoc """
  Schema for the `epic_dependencies` table.

  Represents a directed dependency edge: `epic_id` depends on `depends_on_epic_id`.
  Both epics must belong to the same project.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :epic_id,
             :depends_on_epic_id,
             :inserted_at
           ]}

  schema "epic_dependencies" do
    tenant_field()
    belongs_to :epic, Loopctl.WorkBreakdown.Epic
    belongs_to :depends_on_epic, Loopctl.WorkBreakdown.Epic

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new epic dependency.

  The `tenant_id` is set programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(dep \\ %__MODULE__{}, attrs) do
    dep
    |> cast(attrs, [:epic_id, :depends_on_epic_id])
    |> validate_required([:epic_id, :depends_on_epic_id])
    |> unique_constraint([:epic_id, :depends_on_epic_id],
      message: "dependency already exists"
    )
    |> foreign_key_constraint(:epic_id)
    |> foreign_key_constraint(:depends_on_epic_id)
  end
end
