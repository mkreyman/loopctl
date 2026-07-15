defmodule Loopctl.Workers.RateLimitCounterCleanupWorker do
  @moduledoc """
  Oban worker that periodically deletes expired `rate_limit_counters` windows
  (US-38.2, Epic 38, GH #353).

  The cluster-global Postgres rate limiter (`Loopctl.RateLimiter.Postgres`)
  writes one row per `(bucket, window_start)`. Once a window has rolled over its
  counter is dead weight — only the current window is ever read/updated. This
  worker runs on the Oban Cron plugin and deletes every row whose `window_start`
  is older than a retention floor of `2 ×` the widest window any caller
  configures (see `@retention_ms`), keeping the table small and every
  `check_rate/3` a single indexed row touch.

  The widest window in use today is **1 hour**, not 60s: the per-IP/per-tenant
  RPM plug uses a 60s window, but the signup / WebAuthn-verify / enroll
  anti-abuse gates (`LoopctlWeb.SignupController`, `LoopctlWeb.SignupLive`,
  `LoopctlWeb.TenantAuthenticatorController`) all use `60_000 * 60`. The floor is
  DERIVED from that widest window so an in-flight window of the largest size is
  never pruned out from under a live check (which would reset its counter
  mid-window and over-admit a full budget), and so adding a wider window later
  (e.g. a 24h abuse cap on this shared table) forces the floor to grow with it.

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

  # The widest window any caller configures today: the signup / WebAuthn-verify /
  # enroll anti-abuse gates use `60_000 * 60` (1h). The RPM plug's 60s window is
  # far narrower. If a wider window is ever added, bump this to match.
  @widest_window_ms 3_600_000

  # Retention floor: keep windows whose start is newer than this many ms; delete
  # anything older. Set to `2 ×` the widest window (NOT equal to it — an exact
  # match leaves zero margin, so a still-live largest window sitting right at the
  # floor could be pruned, resetting its counter mid-window and over-admitting a
  # full budget). At `2 ×` a 1h window that opened up to 1h ago is always safely
  # retained while it is in-flight.
  @retention_ms @widest_window_ms * 2

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
