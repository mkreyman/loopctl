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

  # Kinds a caller may write. `checkpoint`, `escalation` and `merge` entries are written by
  # loopctl itself, alongside the state change they describe.
  @caller_kinds [:message, :review_requested, :finding, :fix, :verdict]
  @kinds @caller_kinds ++ [:checkpoint, :escalation, :merge]
  @severities ~w(critical high medium low)

  schema "thread_entries" do
    tenant_field()

    field :story_id, :binary_id
    field :seq, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :author_principal, :string
    field :dispatch_id, :binary_id
    field :idempotency_key, :string
    field :body, :string
    field :checkpoint_id, :binary_id
    field :finding_ids, {:array, :binary_id}, default: []
    field :introduced_by, :string
    field :severity, :string

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
    |> cast(attrs, [
      :kind,
      :idempotency_key,
      :body,
      :checkpoint_id,
      :finding_ids,
      :introduced_by,
      :severity
    ])
    |> validate_required([:kind, :idempotency_key, :body])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_length(:body, min: 1, max: @max_body_bytes, count: :bytes)
    |> validate_inclusion(:severity, @severities)
    |> validate_introduced_by()
  end

  # A checkpoint id, or the literal `none`: the reviewer said so explicitly.
  defp validate_introduced_by(changeset) do
    validate_change(changeset, :introduced_by, fn :introduced_by, value ->
      if value == "none" or match?({:ok, _}, Ecto.UUID.cast(value)),
        do: [],
        else: [introduced_by: "must be a checkpoint id or \"none\""]
    end)
  end
end
