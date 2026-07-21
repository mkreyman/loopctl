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
  `chain_entry_hash`, `failure_reason`, `recorded_at`) and the call `outcome` may
  change — and `outcome` only MONOTONICALLY, from `in_flight` to a terminal
  value, also enforced by that trigger.

  ## Validation lives in the DATABASE, not in a changeset

  There is deliberately no changeset here: the ONLY write path is the raw
  parameterised INSERT in `Loopctl.Custody`, which allocates the sequence number
  in the same statement sequence. A changeset nobody calls reads as enforced
  validation that is not enforced. The invariants are CHECK constraints instead
  (`state`, `outcome`, `subject_type`, `operation`, `operation_sequence >= 0`)
  plus the `(tenant_id, subject_type, subject_id, operation_sequence)` unique
  index, so they hold for every writer including a future one.
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

    # The outcome of the provider call this entry describes. Recorded BEFORE the
    # call (`in_flight`) so a call that egressed and then died still leaves a
    # recorded operation naming the endpoint it went to.
    field :outcome, :string, default: "in_flight"

    field :state, :string, default: "pending"
    field :batch_id, Ecto.UUID
    field :chain_entry_id, Ecto.UUID
    field :chain_position, :integer
    field :chain_entry_hash, :binary
    field :failure_reason, :string
    field :recorded_at, :utc_datetime_usec

    timestamps()
  end

  @outcomes ~w(in_flight succeeded failed)

  @doc "The valid outbox states."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The subject kinds a custody claim can be bound to."
  @spec subject_types() :: [String.t()]
  def subject_types, do: @subject_types

  @doc "The valid provider-call outcomes."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes
end
