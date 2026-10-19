defmodule Loopctl.Changes.Binding do
  @moduledoc """
  Schema for `change_bindings` — a story bound to the chg change that implements it (US-47.1,
  Epic 47 PRD §4).

  - One row per `(tenant_id, repo, change_id)`: a change binds at most one story.
  - At most one CURRENT row per story — `superseded_at IS NULL` — held by the partial unique
    index `change_bindings_one_current_per_story`.
  - `submitter_agent_id` is who submitted the change, as the CALLER resolved it server-side.
    It is informational and never custody: the story's implementer of record stays
    `stories.assigned_agent_id` / `implementer_dispatch_id`, which a binding never writes.
    `submitter_not_claimant` is true when that submitter did not hold the story's claim.

  Only `repo`, `change_id` and `story_id` are cast. `tenant_id`, the submitter fields and
  `superseded_at` are set by `Loopctl.Changes`, never from request data.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @max_length 255

  schema "change_bindings" do
    tenant_field()
    belongs_to :story, Loopctl.WorkBreakdown.Story
    field :repo, :string
    field :change_id, :string
    field :superseded_at, :utc_datetime_usec
    field :submitter_agent_id, :binary_id
    field :submitter_not_claimant, :boolean, default: false

    timestamps()
  end

  @doc "The longest `repo` / `change_id` accepted, shared with `Loopctl.Changes`' input check."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Changeset for a new binding. The caller builds the struct with `tenant_id`, the submitter
  fields set programmatically.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = binding, attrs) do
    binding
    |> cast(attrs, [:story_id, :repo, :change_id])
    |> validate_required([:story_id, :repo, :change_id])
    |> validate_length(:repo, max: @max_length)
    |> validate_length(:change_id, max: @max_length)
    |> unique_constraint([:tenant_id, :story_id], name: :change_bindings_one_current_per_story)
    |> unique_constraint([:tenant_id, :repo, :change_id])
    |> foreign_key_constraint(:story_id)
    |> foreign_key_constraint(:submitter_agent_id)
  end
end
