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

  "Fail open" means BOUNDED admission, for every fault without exception (#564). Whatever
  the shape, the count is unmeasurable, and an unmeasurable count is not evidence that the
  tenant is under threshold — so every class admits only up to a bounded per-tenant JOB
  allowance and is then refused. What the fault decides is the refusal CODE, not whether the
  admissions are bounded:

    * DEMONSTRABLE pool pressure — `connection`, `timeout`, `guc_capture_abort` (raised
      only once the connection is already wedged), `db_pressure` (the
      exhaustion/connection/contention SQLSTATEs a saturated pool raises behind pgbouncer),
      and any exit the gate can place at the DB pool (`ExitClass.pool_exit?/1` on the raw
      reason, not on its metric label) — is refused with the ordinary backlog 429;
    * everything else — a query-shape SQLSTATE (`db_error`, incl. 08P01 protocol_violation),
      a `driver_fault`, a counting-code `throw:*`, and any exit that CANNOT be placed at the
      pool — is refused with a 503 `ingestion_gate_unavailable`, which claims no backlog. A
      deterministic defect in our own counting code must not be reported to a tenant as its
      backlog being too big;
    * the METER itself unreachable (under `RATE_LIMITER=postgres` its store is the same
      `AdminRepo` pool; on the node-local path, its poolboy pool saturating) admits as
      `:unmetered` — 429-ing a tenant whose backlog was neither measured nor metered is a
      code it has not earned — and says so. Those admissions are still bounded, by
      `Loopctl.RateLimiter.FailOpenBackstop`, which shares no pool with either.

  No outcome may ever return a generic 500, and EVERY unmeasurable count stays
  telemetry-visible — admitted, unmetered or refused — so the alert cannot go silent.

  The count is WORKER-scoped (`worker = ContentIngestionWorker`, the sole `:ingestion`
  worker) rather than queue-scoped, so it rides the partial index
  `oban_jobs_ingestion_tenant_idx` and its cost is bounded to the CALLER's own ingestion
  backlog — see `Loopctl.Oban.FairShare`'s "Cost / index justification".
  """
  @callback in_flight_ingestion_backlog(tenant_id :: binary()) :: non_neg_integer()
end
