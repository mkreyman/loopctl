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

  # What a caller writes through the entries API. `checkpoint` entries are written beside the
  # checkpoint they describe; `finding` and `verdict` from a
  # review dispatch over the runner socket, a `finding` from the tenant's human on the thread
  # page (US-45.7), and `fix` from the claimant, each through its own
  # `Loopctl.Threads` entry point (US-45.3); `escalation` and `merge` by
  # the flows that perform those acts.
  # `review_requested` is written by the request-review flow alongside
  # `stories.review_requested_at`, never by a caller: a caller-written one could claim a
  # request the implementer never made, or disagree with the story.
  @caller_kinds [:message]
  @kinds @caller_kinds ++
           [:checkpoint, :review_requested, :finding, :fix, :verdict, :escalation, :merge]

  @severities [:critical, :high, :medium, :low]

  # The knowledge articles an entry may cite (#978): ids only, never bodies, bounded so a
  # thread page and a review payload stay a ledger rather than a reading list. Restated in the
  # migration's CHECK, which must not call application code.
  @max_kb_refs 20
  @kb_ref_kinds [:message, :checkpoint]

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

    # The judgement kinds' fields (US-45.3), every one set by `Loopctl.Threads` after
    # `Loopctl.Threads.Reviews` has validated and canonicalised it, never cast here. `review_id` is the review
    # dispatch a `finding` or `verdict` came from; `introduced_by` is a canonical checkpoint
    # id or `"none"`; `finding_ids` are the findings a `fix` answers.
    field :review_id, :binary_id
    field :severity, Ecto.Enum, values: @severities
    field :location, :string
    field :introduced_by, :string
    field :finding_ids, {:array, Ecto.UUID}

    # The knowledge articles this entry acted on (#978), `message` and `checkpoint` only.
    # `Loopctl.Threads` checks each names an article the writing key can see before the entry
    # is written; the changeset only casts and bounds the list.
    field :kb_refs, {:array, Ecto.UUID}, default: []

    timestamps(updated_at: false)
  end

  @doc "The largest `body`, in bytes, any entry may carry."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The most knowledge articles one entry may cite."
  @spec max_kb_refs() :: pos_integer()
  def max_kb_refs, do: @max_kb_refs

  @doc "The entry kinds that may cite knowledge articles."
  @spec kb_ref_kinds() :: [atom()]
  def kb_ref_kinds, do: @kb_ref_kinds

  @doc """
  A caller's `kb_refs`, cast to canonical lowercase UUIDs with repeats dropped (first
  occurrence kept), or the 422 message naming what is wrong. `nil` is an entry citing nothing.
  """
  @spec cast_kb_refs(term()) :: {:ok, [Ecto.UUID.t()]} | {:error, String.t()}
  def cast_kb_refs(nil), do: {:ok, []}

  def cast_kb_refs(refs) when is_list(refs) do
    case Ecto.Type.cast({:array, Ecto.UUID}, refs) do
      {:ok, ids} ->
        ids = Enum.uniq(ids)

        if length(ids) <= @max_kb_refs,
          do: {:ok, ids},
          else: {:error, "kb_refs may name at most #{@max_kb_refs} articles"}

      _error ->
        {:error, "kb_refs must be a list of knowledge article UUIDs"}
    end
  end

  def cast_kb_refs(_refs), do: {:error, "kb_refs must be a list of knowledge article UUIDs"}

  @doc "A finding's severities, most severe first."
  @spec severities() :: [atom()]
  def severities, do: @severities

  @doc "The entry kinds a caller may write through the API."
  @spec caller_kinds() :: [atom()]
  def caller_kinds, do: @caller_kinds

  @doc "Validates the caller-supplied fields of a new entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :idempotency_key, :body, :checkpoint_id])
    |> put_kb_refs(attrs)
    |> validate_required([:kind, :idempotency_key, :body])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_length(:body, min: 1, max: @max_body_bytes, count: :bytes)
    |> unique_constraint(:idempotency_key, name: :thread_entries_idempotency_uidx)
    |> unique_constraint(:idempotency_key, name: :thread_entries_review_idempotency_uidx)
  end

  # Cast through `cast_kb_refs/1` rather than `cast/3`, so the HTTP surface, a checkpoint's
  # note and this changeset agree on canonical form, de-duplication and the bound. A kind that
  # cites nothing (a finding cites code, not KB) refuses a non-empty list.
  defp put_kb_refs(changeset, attrs) do
    raw = Map.get(attrs, :kb_refs, Map.get(attrs, "kb_refs"))

    case cast_kb_refs(raw) do
      {:ok, []} ->
        put_change(changeset, :kb_refs, [])

      {:ok, ids} ->
        changeset
        |> put_change(:kb_refs, ids)
        |> validate_kb_ref_kind()

      {:error, message} ->
        add_error(changeset, :kb_refs, message)
    end
  end

  defp validate_kb_ref_kind(changeset) do
    kind = get_field(changeset, :kind)

    if is_nil(kind) or kind in @kb_ref_kinds,
      do: changeset,
      else: add_error(changeset, :kb_refs, "only message and checkpoint entries cite articles")
  end

  @doc "The same validation, for an entry loopctl writes itself (a checkpoint's)."
  @spec system_changeset(map()) :: Ecto.Changeset.t()
  def system_changeset(attrs), do: changeset(%__MODULE__{}, attrs)
end
