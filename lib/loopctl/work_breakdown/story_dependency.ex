defmodule Loopctl.WorkBreakdown.StoryDependency do
  @moduledoc """
  Schema for the `story_dependencies` table.

  Represents a directed dependency edge: `story_id` depends on `depends_on_story_id`.
  Both stories must belong to the same project (but may be in different epics).
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :story_id,
             :depends_on_story_id,
             :inserted_at
           ]}

  schema "story_dependencies" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    belongs_to :depends_on_story, Loopctl.WorkBreakdown.Story

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for creating a new story dependency.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(dep \\ %__MODULE__{}, attrs) do
    dep
    |> cast(attrs, [:story_id, :depends_on_story_id])
    |> validate_required([:story_id, :depends_on_story_id])
    |> unique_constraint([:story_id, :depends_on_story_id],
      message: "dependency already exists"
    )
    |> foreign_key_constraint(:story_id)
    |> foreign_key_constraint(:depends_on_story_id)
  end
end
