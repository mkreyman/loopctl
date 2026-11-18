defmodule Loopctl.Workers.ChangeReconcileSweepWorker do
  @moduledoc """
  Finds the chg changes no fleet sender is filling and flags each one for the operator
  (US-47.3 AC-47.3.3, reworked by US-50.2). Runs every five minutes via Oban Cron.

  Two reads, both fleet-wide on `AdminRepo` with a tenant predicate on every join
  (`Loopctl.Changes.Reconcile`): changes with an event held ahead of a gap for over ten
  minutes, and changes bound to a non-terminal story that have been quiet for six hours. A
  change in both is flagged `gap` only. Each read is bounded by `@batch`; the rest are the
  next run's, oldest first. It makes no network call.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Changes.Reconcile

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: sweep(DateTime.utc_now())

  @doc "One sweep at `now`."
  @spec sweep(DateTime.t()) :: :ok
  def sweep(%DateTime{} = now) do
    gaps = Reconcile.gap_candidates(now, @batch)
    stale = Reconcile.stale_candidates(now, @batch) -- gaps

    flagged =
      Enum.count(gaps, &(Reconcile.flag(&1, :gap, now) == :flagged)) +
        Enum.count(stale, &(Reconcile.flag(&1, :stale, now) == :flagged))

    if flagged > 0 do
      Logger.info("ChangeReconcileSweepWorker: #{flagged} change(s) flagged for attention")
    end

    :ok
  end
end
