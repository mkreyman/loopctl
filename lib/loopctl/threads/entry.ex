defmodule Loopctl.Threads.Entry do
  @moduledoc """
  One entry in a story's change thread (`thread_entries`, US-45.1): text a session or a person
  wrote on purpose about the change, never a transcript.

  `body` is UNTRUSTED. It is bounded here, stored verbatim, never executed, and every read
  surface marks it untrusted. `tenant_id`, `story_id`, `seq`, `author_principal` and
  `dispatch_id` are set by `Loopctl.Threads` from the authenticating key and are never cast.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  # One bound, read by the changeset AND the OpenAPI operation, so the two cannot drift.
  @max_body_bytes 16_384

  # What a caller writes through the API. `checkpoint` entries are written beside the
  # checkpoint they describe; `finding`, `fix` and `verdict` belong to the review dispatch
  # (US-45.3); `escalation` and `merge` to the flows that perform those acts. The kind column
  # admits all of them so those stories need no migration to start writing.
  @caller_kinds [:message, :review_requested]
  @kinds @caller_kinds ++ [:checkpoint, :finding, :fix, :verdict, :escalation, :merge]

  schema "thread_entries" do
    tenant_field()

    field :story_id, :binary_id
    field :seq, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :author_principal, :string
    field :dispatch_id, :binary_id
    field :idempotency_key, :string
    field :body, :string
    # `Ecto.UUID`, not `:binary_id`: it CASTS a caller's value to the canonical lowercase form
    # (and refuses a non-UUID at the changeset), so a stored id and a resent one compare equal.
    field :checkpoint_id, Ecto.UUID

    timestamps(updated_at: false)
  end

  @doc "The largest `body`, in bytes, any entry may carry."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The entry kinds a caller may write through the API."
  @spec caller_kinds() :: [atom()]
  def caller_kinds, do: @caller_kinds

  @doc "Validates the caller-supplied fields of a new entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :idempotency_key, :body, :checkpoint_id])
    |> validate_required([:kind, :idempotency_key, :body])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_length(:body, min: 1, max: @max_body_bytes, count: :bytes)
    |> unique_constraint(:idempotency_key, name: :thread_entries_idempotency_uidx)
  end

  @doc "The same validation, for an entry loopctl writes itself (a checkpoint's)."
  @spec system_changeset(map()) :: Ecto.Changeset.t()
  def system_changeset(attrs), do: changeset(%__MODULE__{}, attrs)
end
