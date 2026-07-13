defmodule Loopctl.Telemetry.ObanStatsBehaviour do
  @moduledoc """
  DI seam (US-34.1) for the `oban_jobs` observability poll.

  Split out from `Loopctl.Telemetry.ScaleMetrics.dispatch_oban_stats/0` purely so the
  poller's error-resilience (AC-34.1.3 / TC-34.1.3) can be exercised deterministically
  via `Mox.expect/3` raising — without needing to reproduce a real Postgres failure
  (connection loss, statement_timeout race) to test the rescue path. Resolved via
  `Application.get_env(:loopctl, :oban_stats_query, Loopctl.Telemetry.ObanStats)`; the
  real implementation is `Loopctl.Telemetry.ObanStats`, the test double is
  `Loopctl.MockObanStats` (the DataCase default stub delegates to the real module so
  every other test still exercises the genuine `oban_jobs` read).
  """

  @doc "Per-(state, queue) row counts from `oban_jobs` (AC-34.1.1)."
  @callback job_state_counts() :: [
              {state :: String.t(), queue :: String.t(), count :: non_neg_integer()}
            ]

  @doc """
  Count of `executing` jobs whose `attempted_at` is older than `threshold_minutes`
  (AC-34.1.2 — the signal that `Oban.Plugins.Lifeline` is falling behind, or a job is
  genuinely wedged).
  """
  @callback executing_orphan_count(threshold_minutes :: pos_integer()) :: non_neg_integer()
end
