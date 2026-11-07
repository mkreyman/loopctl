defmodule Loopctl.Workers.VerifyDispatchWorker do
  @moduledoc """
  Asks a runner apart from the implementer's to verify each pull-request-route story at `ci`
  whose head has no verification, once a minute (Epic 48, US-48.18).

  The cron caller of `Loopctl.Agents.Dispatcher.run/2` with `verify@1`
  (`Loopctl.Agents.Specs.VerifyV1`), which owns the selection, the placement
  (`Loopctl.Agents.VerifierPlacement`) and every refusal — the shape and cadence of
  `Loopctl.Workers.ReplyDraftDispatchWorker`, judged by `TriageDispatchWorker.run_result/1`.

  Behind `:dispatch_driver_enabled`, the switch every unattended pass shares: off, a pass
  reads nothing and reports a clean run. Without it running, no pr-route story is ever
  verified and the merge gate refuses every one, which is the state before US-48.18.

  Each run first sweeps for recorded verdicts whose job was never inserted
  (`Loopctl.Agents.VerifyVerdict.enqueue_unapplied/1`) — the node died between the ledger
  commit and the insert. That sweep is NOT behind the switch: it dispatches nothing, it only
  finishes applying an answer a runner already gave.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.VerifyV1
  alias Loopctl.Agents.VerifyVerdict
  alias Loopctl.Workers.TriageDispatchWorker

  require Logger

  @batch 20

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :ok
          | {:error, {:all_candidates_errored, pos_integer()}}
          | {:cancel, {:misconfigured, atom()}}
  def perform(%Oban.Job{}) do
    _ = VerifyVerdict.enqueue_unapplied(@batch)

    case Dispatcher.run(VerifyV1.spec(), limit: @batch) do
      {:ok, results} -> report(results)
      {:error, {_shape, key}} -> misconfigured(key)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  defp report(results) do
    tally = Enum.frequencies(results)
    if map_size(tally) > 0, do: Logger.info("VerifyDispatchWorker: #{inspect(tally)}")

    TriageDispatchWorker.run_result(results)
  end

  # CANCELLED, not failed: no retry changes an environment variable.
  defp misconfigured(key) do
    Logger.error(
      "VerifyDispatchWorker: enabled but #{key} is unusable — verifying nothing. " <>
        "Set it in config; there is deliberately no default."
    )

    {:cancel, {:misconfigured, key}}
  end
end
