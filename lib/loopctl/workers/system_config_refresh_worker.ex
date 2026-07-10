defmodule Loopctl.Workers.SystemConfigRefreshWorker do
  @moduledoc """
  Oban cron worker that re-primes the `Loopctl.SystemConfig` `:persistent_term`
  cache from the DB every minute, so a `system_configs` UPDATE propagates to every
  node within ~60s without a redeploy.

  `SystemConfig.refresh/0` is itself `try/rescue`-wrapped (a DB blip logs and
  no-ops), so this worker's `perform/1` always returns `:ok`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Loopctl.SystemConfig

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    SystemConfig.refresh()
    :ok
  end
end
