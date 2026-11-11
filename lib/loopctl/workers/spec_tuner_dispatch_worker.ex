defmodule Loopctl.Workers.SpecTunerDispatchWorker do
  @moduledoc """
  Runs the improvement loop once a week (Epic 48, US-48.13): `Loopctl.Agents.Tuning.run/1`
  with `spec_tuner@1` (`Loopctl.Agents.Specs.SpecTunerV1`), which picks every (project, target
  spec) whose run outcomes have gathered `SpecTunerV1.min_outcome_rows/0` rows since its last
  tuning run and sends one `spec_tune` dispatch for each.

  OFF TWICE OVER, as every `:draft` pass is: it runs only while the unattended loop is on
  (`:dispatch_driver_enabled`) AND drafting is (`:draft_dispatch_enabled`,
  `DRAFT_DISPATCH_ENABLED`, default off). Off, a pass reads nothing and reports a clean run.
  What it produces is a stored draft a person turns into a pull request or not; nothing this
  worker calls edits a template or a spec.

  Weekly because the threshold is a COUNT of new runs, and a week is the cadence at which a
  person can read what it proposes. The cron entry is in `Loopctl.ObanConfig`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Loopctl.Agents.Tuning

  require Logger

  @batch 20

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:cancel, {:misconfigured, atom()}}
  def perform(%Oban.Job{}) do
    case Tuning.run(limit: @batch) do
      {:ok, results} -> report(results)
      {:error, {_shape, key}} -> misconfigured(key)
    end
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  # Every candidate errored is a failure worth a retry; anything else is a pass that ran.
  defp report(results) do
    tally = results |> Enum.map(fn {_candidate, outcome} -> outcome end) |> Enum.frequencies()
    if map_size(tally) > 0, do: Logger.info("SpecTunerDispatchWorker: #{inspect(tally)}")

    case tally do
      %{errored: errored} when errored == length(results) ->
        {:error, {:all_candidates_errored, errored}}

      _ ->
        :ok
    end
  end

  # CANCELLED, not failed: no retry changes an environment variable.
  defp misconfigured(key) do
    Logger.error(
      "SpecTunerDispatchWorker: enabled but #{key} is unusable — tuning nothing. " <>
        "Set it in config; there is deliberately no default."
    )

    {:cancel, {:misconfigured, key}}
  end
end
