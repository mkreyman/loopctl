defmodule Loopctl.Workers.DispatchDriverWorker do
  @moduledoc """
  Places queued stories on connected runners, once a minute (issue #803).

  The cron caller of `Loopctl.Delivery.DispatchDriver.run/1`, which is where the selection and
  every refusal live. This module is the schedule and the job's own result, and nothing else.

  ## It does nothing until an operator turns it on

  `:dispatch_driver_enabled` defaults to FALSE, so on every deploy until someone sets it this
  worker runs, places nothing and reports `:ok`. That is deliberate rather than a staging
  convenience: this is the one component of the loop that runs code on someone's machines and
  spends their money with nobody watching, and a default of ON would make that a consequence
  of deploying rather than a decision.

  `:dispatch_wall_clock_seconds` and `:dispatch_max_turns` have no default at all. ENABLED
  with either unset, the job FAILS rather than placing on a budget nobody chose — see
  `run_result/1`.

  ## A MINUTE, and bounded per pass

  The same cadence and the same reason as `Loopctl.Workers.TriageTriggerWorker`: a candidate
  is local statements on `AdminRepo` plus one push to an already-connected socket, so the
  bound is about not holding that three-connection pool rather than about anyone's rate limit.
  A remainder is simply the next pass's first candidates, because the read is oldest-first.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Loopctl.Delivery.DispatchDriver

  require Logger

  @batch 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case DispatchDriver.run(@batch) do
      {:ok, results} -> report(results)
      {:error, reason} -> misconfigured(reason)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The job's result for a pass whose candidates produced `results`.

  A pass where EVERY candidate errored is a systemic failure and must not report a clean run —
  the lesson `Loopctl.Workers.IntakeIssueCloseWorker` records and `TriageTriggerWorker`
  repeats: on a pool outage every candidate raises, the per-story rescue swallows each, and an
  `:ok` here would have Oban record success with nothing retried and nothing alerting.

  `:no_runner` is NOT a failure. It is the ordinary state of a fleet with nothing connected,
  and a job that failed on it would retry, alert and eventually discard for a condition that
  is simply "nobody is working right now".

  Public because a whole-pass failure is the one outcome a fixture cannot produce.
  """
  @spec run_result([DispatchDriver.outcome()]) ::
          :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def run_result(results) when is_list(results),
    do: all_errored(Enum.count(results, &(&1 == :errored)), length(results))

  defp all_errored(count, count) when count > 0, do: {:error, {:all_candidates_errored, count}}
  defp all_errored(_errored, _total), do: :ok

  defp report(results) do
    tally = Enum.frequencies(results)

    if map_size(tally) > 0 do
      Logger.info("DispatchDriverWorker: #{inspect(tally)}")
    end

    run_result(results)
  end

  # ENABLED AND HALF-CONFIGURED IS A FAILURE, not a quiet no-op. An operator who turned the
  # driver on and left a budget unset has said they want stories placed; answering `:ok` would
  # leave them watching a queue that never drains with nothing to read. The job fails, Oban
  # retries and then surfaces it, and the reason names the key.
  defp misconfigured({:unset, key}) do
    Logger.error(
      "DispatchDriverWorker: enabled but #{key} is unset — placing nothing. " <>
        "Set it in config; there is deliberately no default."
    )

    {:error, {:unset, key}}
  end
end
