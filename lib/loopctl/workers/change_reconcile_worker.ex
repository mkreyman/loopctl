defmodule Loopctl.Workers.ChangeReconcileWorker do
  @moduledoc """
  Pulls ONE chg change's missing events from chg-server (US-47.3, AC-47.3.3) —
  `Loopctl.Changes.Reconcile.pull/4`.

  Enqueued by `Loopctl.Workers.ChangeReconcileSweepWorker` for a change with a gap older than
  ten minutes or a bound change quiet for six hours. **Unique on the change**
  (`tenant_id`, `repo`, `change_id`) across every incomplete state, so however many sweeps
  see the same change, one job pulls it; `reason` is informational and not part of the key.

  Args carry ids only. The secret is read from the source when the job runs and never
  persisted in `oban_jobs`.

  A final answer (`chg_server_unconfigured`, `no_chg_source`, `unknown_change`,
  `pull_unauthorized`, `source_refused`) cancels the job: retrying it cannot change the
  answer, and the sweep asks again after the interval. Anything else is transient and Oban
  retries it with its backoff.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:tenant_id, :repo, :change_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Loopctl.Changes.Reconcile

  @final [
    :chg_server_unconfigured,
    :no_chg_source,
    :unknown_change,
    :pull_unauthorized,
    :source_refused
  ]

  @doc ~s(The job for one change; `reason` is "gap" or "stale".)
  @spec job(Reconcile.candidate(), String.t()) :: Oban.Job.changeset()
  def job(%{tenant_id: tenant_id, repo: repo, change_id: change_id}, reason) do
    new(%{"tenant_id" => tenant_id, "repo" => repo, "change_id" => change_id, "reason" => reason})
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"tenant_id" => tenant_id, "repo" => repo, "change_id" => change_id}
      }) do
    case Reconcile.pull(tenant_id, repo, change_id) do
      {:ok, _result} -> :ok
      {:error, reason} when reason in @final -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
