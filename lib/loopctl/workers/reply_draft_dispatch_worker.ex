defmodule Loopctl.Workers.ReplyDraftDispatchWorker do
  @moduledoc """
  Asks a runner to draft a reply for each support ticket triage set aside, once a minute
  (Epic 48, US-48.9).

  The cron caller of `Loopctl.Agents.Dispatcher.run/2` with `reply_draft@1`
  (`Loopctl.Agents.Specs.ReplyDraftV1`), which owns the selection and every refusal — the
  same shape, cadence and reasons as `Loopctl.Workers.TriageDispatchWorker`, whose
  `run_result/1` judges this pass too.

  OFF TWICE OVER. A `:draft` pass runs only while the unattended loop is on
  (`:dispatch_driver_enabled`) AND drafting is (`:draft_dispatch_enabled`,
  `DRAFT_DISPATCH_ENABLED`, default off): a drafter is new work on an operator's machines that
  no ticket needed before, so turning the loop on must not start it. Off, a pass reads nothing
  and reports a clean run. What it produces is a stored draft a person sends or not; nothing
  is sent by this worker or by anything it calls.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.ReplyDraftV1
  alias Loopctl.Workers.TriageDispatchWorker

  require Logger

  @batch 20

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) ::
          :ok
          | {:error, {:all_candidates_errored, pos_integer()}}
          | {:cancel, {:misconfigured, atom()}}
  def perform(%Oban.Job{}) do
    case Dispatcher.run(ReplyDraftV1.spec(), limit: @batch) do
      {:ok, results} -> report(results)
      {:error, {_shape, key}} -> misconfigured(key)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  defp report(results) do
    tally = Enum.frequencies(results)
    if map_size(tally) > 0, do: Logger.info("ReplyDraftDispatchWorker: #{inspect(tally)}")

    TriageDispatchWorker.run_result(results)
  end

  # CANCELLED, not failed, for the reason the triage worker gives: no retry changes an
  # environment variable.
  defp misconfigured(key) do
    Logger.error(
      "ReplyDraftDispatchWorker: enabled but #{key} is unusable — drafting nothing. " <>
        "Set it in config; there is deliberately no default."
    )

    {:cancel, {:misconfigured, key}}
  end
end
