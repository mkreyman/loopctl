defmodule Loopctl.Workers.TriageDispatchWorker do
  @moduledoc """
  Asks a runner to triage what intake has detected, once a minute (issue #803 §4).

  The cron caller of `Loopctl.Delivery.TriageDispatcher.run/1`, which owns the selection and
  every refusal. Same shape, same cadence and the same reasons as
  `Loopctl.Workers.DispatchDriverWorker`: a candidate is local statements plus one push to an
  already-connected socket, so the bound is AdminRepo's three-connection pool rather than
  anyone's rate limit, and a remainder is the next pass's first candidates because the read is
  oldest-first.

  OFF with the driver. `:dispatch_driver_enabled` gates both, so an operator turns the
  unattended loop on once rather than reaching a state where stories are triaged and never
  placed, or placed and never triaged.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Loopctl.Delivery.TriageDispatcher

  require Logger

  @batch 20

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :ok
          | {:error, {:all_candidates_errored, pos_integer()}}
          | {:cancel, {:misconfigured, atom()}}
  def perform(%Oban.Job{}) do
    case TriageDispatcher.run(@batch) do
      {:ok, results} -> report(results)
      {:error, {_shape, key}} -> misconfigured(key)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The job's result for a pass whose candidates produced `results`.

  A pass where EVERY candidate errored is a systemic failure and must not report a clean run.
  `:no_runner` is not a failure — it is the ordinary state of a fleet where no machine
  declares `triage` yet, which is every machine until the runners ship their accept path — and
  neither is `:blocked`, which the dispatcher already surfaces at ERROR naming the tenant.
  """
  @spec run_result([TriageDispatcher.outcome()]) ::
          :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def run_result(results) when is_list(results),
    do: all_errored(Enum.count(results, &(&1 == :errored)), length(results))

  defp all_errored(count, count) when count > 0, do: {:error, {:all_candidates_errored, count}}
  defp all_errored(_errored, _total), do: :ok

  defp report(results) do
    tally = Enum.frequencies(results)
    if map_size(tally) > 0, do: Logger.info("TriageDispatchWorker: #{inspect(tally)}")
    run_result(results)
  end

  # CANCELLED, not failed: three failures and a discard per minute for as long as a variable is
  # unset is noise, and no retry changes an environment variable.
  defp misconfigured(key) do
    Logger.error(
      "TriageDispatchWorker: enabled but #{key} is unusable — dispatching nothing. " <>
        "Set it in config; there is deliberately no default."
    )

    {:cancel, {:misconfigured, key}}
  end
end
