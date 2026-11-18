defmodule Loopctl.Changes.Cursor do
  @moduledoc """
  Schema for `change_cursors` — how far one chg change's events have been applied (US-47.3).

  - `applied_seq` is the highest `event_seq` applied; `0` before the first. Events apply in
    order, so every event at or below it is applied and the next to apply is
    `applied_seq + 1`.
  - `last_event_at` is when an event of this change last ARRIVED. The staleness sweep reads
    it: a bound change that has gone quiet for six hours needs attention.
  - `attention` is `"gap"` or `"stale"` while the reconcile sweep has flagged the change
    (`Loopctl.Changes.Reconcile`, US-50.2), with `attention_at` when it was flagged. loopctl
    cannot reach the fleet's outboxes, so a flag alerts the operator once; a sender fills the
    gap by resending from the cursor, and the next applied event clears the flag.
  - `source_id` is the source the last event arrived through.

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
    field :attention, :string
    field :attention_at, :utc_datetime_usec

    timestamps()
  end
end
