defmodule Loopctl.Oban.BacklogCounterBehaviour do
  @moduledoc """
  Behaviour for the in-flight backlog count the batch-ingest admission gate
  (US-36.3, `LoopctlWeb.KnowledgeIngestionController.create_batch/2`) consults.

  Extracted purely so the count is a config-swappable DI seam. Production/dev
  resolve it to `Loopctl.Oban.FairShare` (the real bounded, tenant-scoped,
  index-backed count); `config/test.exs` maps a Mox mock whose default stub delegates
  back to the real `FairShare.in_flight_ingestion_backlog/1` (so the existing backlog
  tests exercise the real count unchanged), while the fail-open tests override it with
  `Mox.expect/3` to RAISE a DB error, or to EXIT the way a wedged pool checkout really
  does — deterministically driving the gate's fail-open path.

  What "fail open" means here has TWO branches, and the difference is the fault, not the
  tenant:

    * a fault that is not backlog pressure — a query-shape SQLSTATE (`db_error`) or
      `LocalGuc`'s deliberate refusal (`guc_capture_abort`) — ADMITS unconditionally;
    * a SUSTAINED pool-pressure fault (`connection`, `timeout`, `exit:*`, `throw:*`, and
      `db_pressure` — the resource-exhaustion / connection SQLSTATEs a saturated pool
      raises behind pgbouncer) admits up to a bounded per-tenant JOB allowance and then
      returns the ordinary backlog 429 — unbounded admission on these made "no
      backpressure at all" the steady state during exactly the overload the valve bounds.

  Neither branch may ever return a generic 500, and EVERY unmeasurable count stays
  telemetry-visible — admitted or refused — so the alert cannot go silent.

  The count is WORKER-scoped (`worker = ContentIngestionWorker`, the sole `:ingestion`
  worker) rather than queue-scoped, so it rides the partial index
  `oban_jobs_ingestion_tenant_idx` and its cost is bounded to the CALLER's own ingestion
  backlog — see `Loopctl.Oban.FairShare`'s "Cost / index justification".
  """
  @callback in_flight_ingestion_backlog(tenant_id :: binary()) :: non_neg_integer()
end
