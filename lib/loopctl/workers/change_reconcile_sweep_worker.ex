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
  `CHG_SERVER_URL` is unset the sweep returns BEFORE either read: no job could pull, so the
  fleet-wide scans would buy nothing, and enqueuing one per candidate would only fill the queue
  with cancellations. That is the default until chg-server runs, so the warning saying so is
  logged once per node and at debug on every sweep after it (the once-per-node
  `:persistent_term` flag `Loopctl.Knowledge` uses for its own config-state warning).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Changes.ChgClient
  alias Loopctl.Changes.Reconcile
  alias Loopctl.TermCache
  alias Loopctl.Workers.ChangeReconcileWorker

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sweep(DateTime.utc_now(), ChgClient.base_url())
  end

  @doc """
  One sweep at `now`. `base_url` is `ChgClient.base_url/0` in production; an argument so the
  unconfigured case is testable without touching config.

  `opts`: `:warned_in` — the `Loopctl.TermCache` namespace the once-per-node "unconfigured"
  flag lives in (default this module, i.e. `:persistent_term`); a test passes its own ETS
  table.
  """
  @spec sweep(DateTime.t(), String.t() | nil, keyword()) :: :ok
  def sweep(now, base_url, opts \\ [])

  def sweep(%DateTime{}, nil, opts) do
    warn_unconfigured(Keyword.get(opts, :warned_in, __MODULE__))
  end

  def sweep(%DateTime{} = now, base_url, _opts) when is_binary(base_url) do
    gaps = Reconcile.gap_candidates(now, @batch)
    stale = Reconcile.stale_candidates(now, @batch)

    if gaps != [] or stale != [] do
      jobs =
        Enum.map(gaps, &ChangeReconcileWorker.job(&1, "gap")) ++
          Enum.map(stale -- gaps, &ChangeReconcileWorker.job(&1, "stale"))

      Enum.each(jobs, &Oban.insert!/1)

      Logger.info(
        "ChangeReconcileSweepWorker: #{length(gaps)} gapped, #{length(stale)} quiet " <>
          "change(s) enqueued for a pull"
      )
    end

    :ok
  end

  defp warn_unconfigured(namespace) do
    if TermCache.get(namespace, :unconfigured_warned, false) do
      Logger.debug("ChangeReconcileSweepWorker: CHG_SERVER_URL is unset; sweep skipped")
    else
      TermCache.put(namespace, :unconfigured_warned, true)

      Logger.warning(
        "ChangeReconcileSweepWorker: CHG_SERVER_URL is unset, so no chg change is reconciled " <>
          "on this node (logged once per node; later sweeps skip at debug)"
      )
    end

    :ok
  end
end
