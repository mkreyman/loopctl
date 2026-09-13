defmodule Loopctl.Runners.DispatchRecord do
  @moduledoc """
  Schema for the `runner_dispatches` table — the dispatch ledger (issue #803).

  `Loopctl.Runners.dispatch/3` writes one row per `dispatch_id` BEFORE it broadcasts, so the
  identity of the outward side effect exists before the side effect does. The runner's
  `dispatch_reply` moves the row out of `sent` once (`Loopctl.Runners.DispatchLedger`), the
  first trace batch of the accepted run binds `run_id`, and `trace_acked_seq` is that run's
  contiguous trace cursor (-1 before any event is stored).

  ## Status

  - `sent` — handed to the runner's channel. Not delivered: the channel may still drop it
    (a halt, a second socket), and re-dispatching the same `dispatch_id` re-sends it.
  - `accepted` / `refused` — the runner's reply. Terminal for the reply; a refusal carries a
    `reason` (`RunnerContract.refusal_reasons/0`).
  - `superseded` — the claim this dispatch served was reclaimed. Written by the reclaim path,
    never by the runner.

  ## Trust boundary

  Every field is set programmatically in `Loopctl.Runners`; there is no caller changeset.

  ## Isolation

  `AdminRepo` plus an explicit `tenant_id` predicate in every query, the convention of
  `Loopctl.Runners`. RLS is ENABLED on the table as defense-in-depth.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(sent accepted refused superseded)

  schema "runner_dispatches" do
    tenant_field()
    field :runner_id, :binary_id
    field :dispatch_id, :binary_id
    field :story_id, :binary_id
    field :claim_epoch, :integer
    field :kind, :string
    field :status, :string, default: "sent"
    field :reason, :string
    field :reason_detail, :string
    field :replied_at, :utc_datetime_usec
    field :run_id, :binary_id
    field :trace_acked_seq, :integer, default: -1

    timestamps()
  end

  @doc "Every status a ledger row can hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
