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

  What "fail open" means here depends on the fault, not on the tenant:

    * not backlog pressure — a query-shape SQLSTATE (`db_error`, incl. 08P01
      protocol_violation) — ADMITS unconditionally;
    * POOL pressure (`connection`, `timeout`, `exit:*`, `throw:*`, `guc_capture_abort`
      — raised only once the connection is already wedged — and `db_pressure`, the
      exhaustion/connection SQLSTATEs a saturated pool raises behind pgbouncer) admits
      up to a bounded per-tenant JOB allowance, then returns the ordinary backlog 429:
      unbounded admission here made "no backpressure at all" the steady state;
    * the METER itself unreachable (under `RATE_LIMITER=postgres` its store is the same
      `AdminRepo` pool) admits as `:unmetered` — 429-ing a tenant whose backlog was
      neither measured nor metered is a code it has not earned — and says so.

  No outcome may ever return a generic 500, and EVERY unmeasurable count stays
  telemetry-visible — admitted, unmetered or refused — so the alert cannot go silent.

  The count is WORKER-scoped (`worker = ContentIngestionWorker`, the sole `:ingestion`
  worker) rather than queue-scoped, so it rides the partial index
  `oban_jobs_ingestion_tenant_idx` and its cost is bounded to the CALLER's own ingestion
  backlog — see `Loopctl.Oban.FairShare`'s "Cost / index justification".
  """
  @callback in_flight_ingestion_backlog(tenant_id :: binary()) :: non_neg_integer()
end
