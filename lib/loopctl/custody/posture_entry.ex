defmodule Loopctl.Custody.PostureEntry do
  @moduledoc """
  US-41.7 — ONE recorded egress posture for ONE content-touching operation on ONE
  article or memory row (AC-41.7.1).

  This is an APPEND-ONLY SEQUENCE, not a write-time snapshot: a create, each
  embedding, each re-embed and each classification/merge that touches the content
  gets its OWN entry carrying the posture RESOLVED at that moment. A single
  snapshot would be falsified the first time an async embedding job shipped the
  body to a different endpoint.

  The row doubles as the OUTBOX (AC-41.7.2): `operation_sequence` is assigned
  inside the content transaction, so a claim reader can require the recorded
  entries to form a CONTIGUOUS sequence and degrade to `incomplete` on any gap
  rather than reporting a satisfied attestation.

  ## What is immutable

  Everything the entry ASSERTS — subject, sequence, operation, posture,
  `local_endpoints_only`, `occurred_at` — is immutable, enforced by a database
  trigger (`custody_posture_entries_immutable_trigger`). Only the flush
  bookkeeping (`state`, `batch_id`, `chain_entry_id`, `chain_position`,
  `failure_reason`, `recorded_at`) may change.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @states ~w(pending recorded failed)
  @subject_types ~w(article memory)

  schema "custody_posture_entries" do
    tenant_field()

    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :operation_sequence, :integer
    field :operation, :string
    field :posture, :map, default: %{}
    field :local_endpoints_only, :boolean, default: false
    field :occurred_at, :utc_datetime_usec

    field :state, :string, default: "pending"
    field :batch_id, Ecto.UUID
    field :chain_entry_id, Ecto.UUID
    field :chain_position, :integer
    field :failure_reason, :string
    field :recorded_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The valid outbox states."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The subject kinds a custody claim can be bound to."
  @spec subject_types() :: [String.t()]
  def subject_types, do: @subject_types

  @doc """
  Changeset for a newly ASSIGNED entry. `tenant_id` is never cast — it is set on
  the struct by the caller (CLAUDE.md multi-tenant rule 4).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :subject_type,
      :subject_id,
      :operation_sequence,
      :operation,
      :posture,
      :local_endpoints_only,
      :occurred_at,
      :state
    ])
    |> validate_required([
      :subject_type,
      :subject_id,
      :operation_sequence,
      :operation,
      :posture,
      :occurred_at
    ])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:state, @states)
    |> validate_number(:operation_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:tenant_id, :subject_type, :subject_id, :operation_sequence],
      name: :custody_posture_entries_row_sequence_idx
    )
  end
end
