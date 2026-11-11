defmodule Loopctl.Changes.Cursor do
  @moduledoc """
  Schema for `change_cursors` — how far one chg change's events have been applied (US-47.3).

  - `applied_seq` is the highest `event_seq` applied; `0` before the first. Events apply in
    order, so every event at or below it is applied and the next to apply is
    `applied_seq + 1`.
  - `last_event_at` is when an event of this change last ARRIVED (push or pull). The
    staleness reconcile reads it: a bound change that has gone quiet for six hours is pulled.
  - `last_pulled_at` is when loopctl last asked chg-server for this change's events, so one
    quiet change is pulled at most once per reconcile interval rather than on every sweep.
  - `source_id` is the source the last event arrived through. A pull does NOT use it: it
    resolves the repository's live `:chg` source when it runs, so a re-enrolled source (and
    its new secret) is the one asked.

  The row is the per-change LOCK: every ingest takes it `FOR UPDATE` before inserting or
  applying anything (`Loopctl.Changes.Events`).
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "change_cursors" do
    tenant_field()
    field :source_id, :binary_id
    field :repo, :string
    field :change_id, :string
    field :applied_seq, :integer, default: 0
    field :last_event_at, :utc_datetime_usec
    field :last_pulled_at, :utc_datetime_usec

    timestamps()
  end
end
