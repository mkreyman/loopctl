defmodule Loopctl.Runners.TraceEvent do
  @moduledoc """
  Schema for the `runner_trace_events` table — one stored line of a run's NDJSON trace
  (issue #803, design §11).

  The runner's file is the source of truth; this is the copy it resumes into. Rows are
  written only by `Loopctl.Runners.DispatchLedger.record_trace/3`, with
  `ON CONFLICT DO NOTHING` on `(tenant_id, run_id, seq)`, so a re-sent event is stored once
  and the FIRST copy wins.

  Not the audit chain: trace events are observability, and the chain serialises every
  writer on the tenant's latest entry.

  ## Retention

  Rows are deleted past a tenant's window by `Loopctl.Workers.DeliveryLoopPruneWorker`,
  through `Loopctl.Runners.DispatchLedger.prune_trace_events/3` — but only once their
  dispatch is terminal (`runner_dispatches.released_at` set). A run that may still be going
  keeps its whole trace whatever its age. See "Retention" in
  `Loopctl.Runners.DispatchLedger`.

  ## Isolation

  Read and written only through `Loopctl.Runners.DispatchLedger`, on the RLS-enforced
  `Loopctl.Repo` inside `Repo.with_tenant/2`, with an explicit `tenant_id` predicate as
  well. Never `AdminRepo` — see that module.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "runner_trace_events" do
    tenant_field()
    field :runner_dispatch_id, :binary_id
    field :run_id, :binary_id
    field :seq, :integer
    field :event_id, :string
    field :parent, :string
    field :ts, :utc_datetime_usec
    field :type, :string
    field :data, :map, default: %{}

    timestamps(updated_at: false)
  end
end
