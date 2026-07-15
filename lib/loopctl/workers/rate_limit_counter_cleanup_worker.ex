defmodule Loopctl.Workers.RateLimitCounterCleanupWorker do
  @moduledoc """
  Oban worker that periodically deletes expired `rate_limit_counters` windows
  (US-38.2, Epic 38, GH #353).

  The cluster-global Postgres rate limiter (`Loopctl.RateLimiter.Postgres`)
  writes one row per `(bucket, window_start)`. Once a window has rolled over its
  counter is dead weight — only the current window is ever read/updated. This
  worker runs on the Oban Cron plugin and deletes every row whose `window_start`
  is older than a small retention floor (a couple of the widest windows we use),
  keeping the table small and every `check_rate/3` a single indexed row touch.

  Bounded cost: the delete is an index-range scan on `window_start` (backed by
  the dedicated btree index), NOT a full-table scan. Uses `Loopctl.AdminRepo`
  because the table is global/cross-tenant with no `tenant_id` (see the
  migration and `Loopctl.RateLimiter.Postgres` for the access-path rationale).

  When the Postgres limiter is UNSELECTED (the default) the table is empty, so
  this worker deletes nothing — a cheap no-op.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo

  # Retention floor: keep windows newer than this many milliseconds. Generously
  # larger than any window we use (the RPM windows are 60s) so an in-flight
  # window is never pruned out from under a live check; anything older is dead.
  @retention_ms 3_600_000

  @impl Oban.Worker
  def perform(_job) do
    cutoff = System.system_time(:millisecond) - @retention_ms

    {deleted_count, _} =
      from(c in "rate_limit_counters", where: c.window_start < ^cutoff)
      |> AdminRepo.delete_all()

    if deleted_count > 0 do
      require Logger
      Logger.info("RateLimitCounterCleanupWorker deleted #{deleted_count} expired counters")
    end

    :ok
  end
end
