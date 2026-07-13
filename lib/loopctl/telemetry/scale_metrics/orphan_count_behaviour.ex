defmodule Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour do
  @moduledoc """
  DI seam for the US-34.2 Oban orphan-count health sub-check.

  `Loopctl.HealthCheck.Default` calls this (not
  `Loopctl.Telemetry.ScaleMetrics.count_oban_executing_orphans/0` directly) so the
  degraded branch — the `oban_jobs` `:executing` orphan count exceeding the
  configured `:oban_orphan_health_threshold` — is exercisable in tests via
  `Mox.expect/3` without inserting real `oban_jobs` rows or the forbidden
  `Application.put_env`. The default resolution (`Loopctl.Telemetry.ScaleMetrics`,
  which already implements `count_oban_executing_orphans/0` for US-34.1) is
  untouched in dev/prod.
  """

  @callback count_oban_executing_orphans() :: non_neg_integer()
end
