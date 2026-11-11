defmodule Loopctl.Workers.MergeSweepWorker do
  @moduledoc """
  The pull-request route's merge sweep, once a minute (Epic 48, US-48.17):
  `Loopctl.Delivery.MergeExecution.sweep/1`.

  For every pr-route story at `ci` whose stage row names a runner, it holds the claim open
  while that runner is live, escalates the story over `:runner_gone` once the runner has been
  absent past the bound, and enqueues one `Loopctl.Workers.MergeInstructionWorker` per story
  verified at its head with no instruction outstanding.

  Only the INSTRUCTION half is behind `:dispatch_driver_enabled`. Holding a claim and noticing
  a vanished runner start nothing on anyone's machine; they keep work that already ran from
  being reclaimed and re-queued, so gating them would strand every in-flight story the moment
  a fleet turned the driver off (the reasoning `Loopctl.Workers.StoryCompletionWorker`'s
  crontab entry records). Local reads only; the forge is read by the per-story job.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 55, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Delivery.MergeExecution

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = MergeExecution.sweep()
    tally = Enum.frequencies_by(results, &tally_key/1)
    if map_size(tally) > 0, do: Logger.info("MergeSweepWorker: #{inspect(tally)}")
    :ok
  end

  defp tally_key({:error, _reason}), do: :error
  defp tally_key(outcome), do: outcome
end
