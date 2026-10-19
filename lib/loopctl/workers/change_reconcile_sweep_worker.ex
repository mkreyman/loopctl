defmodule Loopctl.Workers.ChangeReconcileSweepWorker do
  @moduledoc """
  Finds the chg changes that need a pull and enqueues one
  `Loopctl.Workers.ChangeReconcileWorker` per change (US-47.3, AC-47.3.3). Runs every five
  minutes via Oban Cron.

  Two reads, both fleet-wide on `AdminRepo` with a tenant predicate on every join
  (`Loopctl.Changes.Reconcile`): changes with an event held ahead of a gap for over ten
  minutes, and changes bound to a non-terminal story that have been quiet for six hours. A
  change in both is enqueued once — the job is unique on the change, so this worker could not
  double it even if it tried. Each read is bounded by `@batch`; the rest are the next run's,
  oldest first.

  It makes no network call itself, so a slow chg-server cannot hold a sweep. When
  `CHG_SERVER_URL` is unset nothing is enqueued: no job could pull, and enqueuing one per
  candidate every five minutes would only fill the queue with cancellations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Changes.ChgClient
  alias Loopctl.Changes.Reconcile
  alias Loopctl.Workers.ChangeReconcileWorker

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sweep(DateTime.utc_now(), ChgClient.base_url())
  end

  @doc """
  One sweep at `now`. `base_url` is `ChgClient.base_url/0` in production; an argument so the
  unconfigured case is testable without touching config.
  """
  @spec sweep(DateTime.t(), String.t() | nil) :: :ok
  def sweep(%DateTime{} = now, base_url) do
    gaps = Reconcile.gap_candidates(now, @batch)
    stale = Reconcile.stale_candidates(now, @batch)

    cond do
      gaps == [] and stale == [] ->
        :ok

      is_nil(base_url) ->
        Logger.warning(
          "ChangeReconcileSweepWorker: #{length(gaps)} gapped and #{length(stale)} quiet " <>
            "change(s) need a pull, but CHG_SERVER_URL is unset; nothing enqueued"
        )

        :ok

      true ->
        jobs =
          Enum.map(gaps, &ChangeReconcileWorker.job(&1, "gap")) ++
            Enum.map(stale -- gaps, &ChangeReconcileWorker.job(&1, "stale"))

        Enum.each(jobs, &Oban.insert!/1)

        Logger.info(
          "ChangeReconcileSweepWorker: #{length(gaps)} gapped, #{length(stale)} quiet " <>
            "change(s) enqueued for a pull"
        )

        :ok
    end
  end
end
