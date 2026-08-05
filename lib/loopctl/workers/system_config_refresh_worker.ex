defmodule Loopctl.Workers.SystemConfigRefreshWorker do
  @moduledoc """
  Oban cron worker that re-primes the `Loopctl.SystemConfig` `:persistent_term`
  cache from the DB every minute, so a `system_configs` UPDATE propagates to every
  node within ~60s without a redeploy.

  `SystemConfig.refresh/0` never raises and never exits — a DB blip logs and
  returns `{:error, reason}`, leaving the existing cache intact. This worker
  deliberately DISCARDS that result and always returns `:ok`: a failed tick needs
  no Oban retry because the next minute's cron tick is the retry.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Loopctl.SystemConfig

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    SystemConfig.refresh()
    :ok
  end
end
