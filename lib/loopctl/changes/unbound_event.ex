defmodule Loopctl.Changes.UnboundEvent do
  @moduledoc """
  Schema for `unbound_change_events` — a bind that named a `story_id` the calling tenant does
  not own (US-47.1 AC-47.1.3, Epic 47 PRD §4: "recorded as an unbound event ... it never binds").

  ## Why a table of its own

  A nullable-story row in `change_bindings` was the alternative, and it is wrong three ways:

  1. **It would collide with the real binding.** `change_bindings` is unique on
     `(tenant_id, repo, change_id)`. An unbound row for change X would occupy that key, so a
     later, correct bind of X to a story the tenant does own would be refused — or the index
     would have to become partial, and "a change binds at most one story" would stop being a
     database fact.
  2. **Every reader would have to filter it out.** A binding row means "this story follows
     this change"; a row with no story is not one, and `current_binding/2` and the stage
     machine's readers would each need to remember that.
  3. **A foreign key is an existence oracle.** `change_bindings.story_id` references
     `stories`. Storing the claimed id there would ACCEPT another tenant's story id (the row
     exists) and REJECT an unknown one, which is exactly the difference the bind's answer
     must not reveal. Here `claimed_story_id` is free text with no foreign key, so a foreign
     id, an unknown id and a malformed one are stored the same way.

  The row lives in the CALLING tenant — it is that tenant's payload that named the id — so
  nothing is ever written into the tenant that owns the story.

  Idempotent on `(tenant_id, repo, change_id, claimed_story_id)`: a redelivered bind records
  nothing new.
  """

  use Loopctl.Schema

  alias Loopctl.Changes.Binding

  @type t :: %__MODULE__{}

  schema "unbound_change_events" do
    tenant_field()
    field :repo, :string
    field :change_id, :string
    field :claimed_story_id, :string
    field :submitter_agent_id, :binary_id

    timestamps(updated_at: false)
  end

  @doc """
  Changeset for a new event. `tenant_id` and `submitter_agent_id` are set on the struct by
  `Loopctl.Changes`, never cast.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, [:repo, :change_id, :claimed_story_id])
    |> validate_required([:repo, :change_id, :claimed_story_id])
    |> validate_length(:repo, max: Binding.max_length())
    |> validate_length(:change_id, max: Binding.max_length())
    |> validate_length(:claimed_story_id, max: Binding.max_length())
    |> foreign_key_constraint(:submitter_agent_id)
  end
end
