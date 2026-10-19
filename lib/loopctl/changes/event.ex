defmodule Loopctl.Changes.Event do
  @moduledoc """
  Schema for `change_events` — one event of one chg change, as chg-server delivered it or as
  loopctl pulled it (US-47.3, Epic 47 PRD §5).

  - One row per `(tenant_id, repo, change_id, event_seq)`; that unique index is the
    idempotency key, so a redelivery inserts nothing.
  - `applied_at` is NULL while the event waits ahead of a gap, and set once the events before
    it have applied. `effect` is what applying it did (`Loopctl.Changes.EventEffects`).
  - `data` is chg's per-kind payload, stored as received. It is UNTRUSTED text: nothing reads
    it as an instruction, and nothing but the effects module reads it at all.
  - `received_via` is `"push"` (the webhook) or `"pull"` (gap or staleness reconciliation).

  Written only by `Loopctl.Changes.Events` from a validated `Loopctl.Changes.Envelope`; there
  is no changeset because no field of this row is ever cast from a request. `tenant_id` and
  `source_id` come from the authenticated source, never from the body.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "change_events" do
    tenant_field()
    field :source_id, :binary_id
    field :repo, :string
    field :change_id, :string
    field :event_seq, :integer
    field :kind, :string
    field :revision, :integer
    field :sha, :string
    field :occurred_at, :utc_datetime_usec
    field :data, :map, default: %{}
    field :received_via, :string
    field :applied_at, :utc_datetime_usec
    field :effect, :map

    timestamps()
  end
end
