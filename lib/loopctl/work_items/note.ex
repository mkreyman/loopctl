defmodule Loopctl.WorkItems.Note do
  @moduledoc """
  A note on a work item (US-52.17): the holder's plan, progress, a decision or an open
  question, appended to `story_notes` and never edited. Written through
  `Loopctl.WorkItems.write_note/4`, which also records a `note_written` event on the item's
  log in the same transaction.

  `tenant_id`, `story_id`, `holder_id` and `author_api_key_id` are set by the server from the
  authenticating key and the path, never cast: a note's author is custody-adjacent identity.
  """

  use Loopctl.Schema

  alias Loopctl.Security.SecretDenylist

  @type t :: %__MODULE__{}

  @sections ~w(plan progress decision question)

  # The channel post body bound (`Loopctl.Coordination.ChannelPost`), in BYTES. The one copy:
  # the schema validates against it and `LoopctlWeb.WorkItemNoteController`'s operation spec
  # states it.
  @max_body_bytes 16_384

  schema "story_notes" do
    tenant_field()
    field :story_id, :binary_id
    field :holder_id, :binary_id
    field :author_api_key_id, :binary_id
    field :section, :string
    field :body, :string
    field :idempotency_key, :string

    timestamps(updated_at: false)
  end

  @doc "The sections a note may be filed under."
  @spec sections() :: [String.t()]
  def sections, do: @sections

  @doc "The largest body a note holds, in bytes (`story_notes_body_size`)."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "A note from the request's `section`, `body` and optional `idempotency_key`."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = note, attrs) do
    note
    |> cast(attrs, [:section, :body, :idempotency_key])
    |> validate_required([:section, :body])
    |> validate_inclusion(:section, @sections)
    |> validate_length(:body, min: 1, max: @max_body_bytes, count: :bytes)
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> validate_change(:body, fn :body, body ->
      if SecretDenylist.contains_secret?(body),
        do: [body: "contains what looks like a credential; notes are readable by every holder"],
        else: []
    end)
  end
end
