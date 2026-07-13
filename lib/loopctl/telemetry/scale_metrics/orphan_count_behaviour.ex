defmodule Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour do
  @moduledoc """
  DI seam for the US-34.2 Oban orphan-count health sub-check.

  `Loopctl.HealthCheck.Default` calls this (not
  `Loopctl.Telemetry.ScaleMetrics.count_oban_executing_orphans/0` directly) so the
  degraded branch — the `oban_jobs` `:executing` orphan count exceeding the
  configured `:oban_orphan_health_threshold` — is exercisable in tests via
  `Mox.expect/3` without inserting real `oban_jobs` rows or the forbidden
  `Application.put_env`.

  Post-review (US-34.2, finding: "readiness-only query on the shared, continuous,
  unauthenticated liveness probe"): the callback reads the value US-34.1's
  `poll_oban_executing_orphans/0` (a `telemetry_poller` periodic measurement,
  ticking every 10s) already cached in `:persistent_term` after its last
  SUCCESSFUL poll, instead of the health check issuing its OWN fresh
  `Repo.transaction` + `SELECT count(*)` on every call — exactly the reuse the
  story's technical_notes preferred ("avoid a second query"). The default
  resolution (`Loopctl.Telemetry.ScaleMetrics`, which implements
  `cached_executing_orphan_count/0`) is untouched in dev/prod: it is the SAME
  process that already runs the poller, so the cache it reads is always its own.
  """

  @callback cached_executing_orphan_count() :: {:ok, non_neg_integer()} | :not_yet_polled
end
