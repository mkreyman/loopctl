defmodule Loopctl.Workers.CustodyPostureSweepWorker do
  @moduledoc """
  US-41.7 — the periodic backstop for custody posture entries that were committed
  but never scheduled.

  `Loopctl.Custody.enqueue_flush/1` runs AFTER the content transaction commits
  (it must — the flush must not be able to fail the article/memory write it merely
  describes) and deliberately swallows an `Oban.insert/1` failure. So a process
  that dies, or an Oban insert that fails, in the window between COMMIT and
  ENQUEUE leaves an outbox row committed `pending` with `batch_id` NULL and
  NOTHING scheduled to flush it.

  Nothing else sweeps for that row: `Custody`'s stranded-row reaper only runs
  INSIDE a flush that some OTHER write for the same tenant happens to enqueue, so
  a tenant that goes quiet keeps the row `claim_pending` indefinitely. It is
  correctly non-positive — a pending claim is never read as an attestation — but
  "in flight forever" is not a state AC-41.7.8 contemplates.

  This cron enqueues the ordinary per-tenant flush for every tenant with entries
  pending longer than `Loopctl.Custody.stale_pending_seconds/0`. It adds no new
  flush machinery, and it is idempotent: the flush job is unique per tenant, and
  a tenant with nothing left to flush costs one no-op job.
  """

  use Oban.Worker, queue: :audit, max_attempts: 3

  alias Loopctl.Custody

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Custody.enqueue_stale_flushes()
    :ok
  end
end
