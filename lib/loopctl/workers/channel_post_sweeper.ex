defmodule Loopctl.Workers.ChannelPostSweeper do
  @moduledoc """
  Oban cron worker that hard-deletes expired coordination-bus posts
  (`Loopctl.Coordination.ChannelPost`), Epic 39 / US-39.5.

  The coordination bus (the third memory plane) is deliberately transient: every
  row carries a uniform 30-day `expires_at`, set server-side in
  `Loopctl.Coordination`. Anything worth keeping longer is already graduated to
  Knowledge, so hard-deleting expired rows loses nothing. This worker deletes
  rows past `expires_at`. Scheduled via the Oban Cron plugin in
  `Loopctl.ObanConfig.plugins/0` (every 5 minutes), following the existing
  cleanup-worker convention (see `Loopctl.Workers.SessionMemoryPruneWorker`).

  Expiry is a uniform, tenant-independent predicate (`expires_at < now()`), so the
  delete runs once across all tenants on the BYPASSRLS `Loopctl.AdminRepo` — never
  a per-tenant loop. `channel_posts` has RLS ENABLED as defense-in-depth, but the
  sweep predicate touches no tenant column, so BYPASSRLS is the correct repo (same
  as the other maintenance crons).

  ## Deliberate deviation from `SessionMemoryPruneWorker`

  The template RECURSES to drain ALL expired rows in a single `perform`. This
  worker does NOT: each invocation deletes AT MOST `@batch_size` rows (a SINGLE
  batch, non-recursive), so a large backlog cannot lock the table in one long
  transaction and the `*/5 * * * *` cron drains any backlog over successive runs.
  The bound is overridable via the job arg `"limit"` (a positive integer) so a
  caller can tune the per-run cap. The sweep is idempotent — with no expired rows
  it is a no-op that deletes zero.

  ## Observability (issue #498)

  Retention is a release gate, so a silently dead sweep silently stops enforcing the
  30-day window. Three signals cover the three distinct failure shapes:

  1. **Ran and succeeded** — `Loopctl.TelemetryEvents.channel_post_sweep_stop/0` is
     emitted on EVERY successful run, INCLUDING a zero-delete no-op. Emitting only on
     a non-zero delete (the pre-#498 behavior) cannot distinguish "nothing to do" from
     "never ran".
  2. **Ran and failed** — a raise/DB error is caught, logged at `error`, emitted as
     `channel_post_sweep_exception/0`, and then **RE-RAISED**. The rescue is purely
     observational: Oban must still record the failure and retry (`max_attempts: 3`).
     Swallowing it here would hide the fault behind an `:ok`.
  3. **Never ran at all** — the load-bearing half, since a worker that stops being
     SCHEDULED emits neither event above. `Loopctl.Knowledge.IngestionHealth`'s
     `:sweep_stalled` detector (an `ingestion_anomalies` type, run hourly by
     `Loopctl.Workers.IngestionHealthWorker`) flags any tenant whose expired
     `channel_posts` are still present beyond a grace window, and raises the operator
     alert. That detector is deliberately **per-tenant on overdue rows** rather than a
     global "last completed job" heartbeat over `oban_jobs`: a tenant with overdue
     expired rows is, by construction, a tenant whose retention is NOT being enforced —
     it observes the OUTCOME (rows that should be gone are present) rather than a proxy
     for the mechanism, so it also catches a sweep that runs but silently deletes
     nothing (a bad predicate, a permission regression, a backlog the batch bound can
     never drain). The `oban_jobs` heartbeat was considered and skipped: it is
     tenant-independent (so it could not satisfy the tenant-scoped anomaly row the
     alerting surface uses) and it is only as durable as `Oban.Plugins.Pruner`'s
     terminal-job retention.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.TelemetryEvents

  @batch_size 1000

  @doc """
  Deletes at most one batch of expired channel posts (`expires_at < now()`).

  Reads the `"limit"` job arg (a positive integer) as the per-run batch bound,
  defaulting to `#{@batch_size}`. Returns `:ok` whether or not anything was
  deleted (idempotent); logs the count only when it is positive.

  Emits `Loopctl.TelemetryEvents.channel_post_sweep_stop/0` on EVERY successful run
  (zero-delete runs included). On a raise it logs at `error`, emits
  `channel_post_sweep_exception/0`, and RE-RAISES so Oban records the failure and
  retries — see the moduledoc's "Observability" section.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: args}) do
    limit = batch_limit(args)

    try do
      count = sweep_batch(limit)

      # Always-on success signal, INCLUDING count == 0: "swept, nothing to do" and
      # "never ran" must be distinguishable from the outside.
      :telemetry.execute(
        TelemetryEvents.channel_post_sweep_stop(),
        %{deleted: count},
        %{limit: limit}
      )

      if count > 0 do
        Logger.info("ChannelPostSweeper deleted #{count} expired channel posts")
      end

      :ok
    rescue
      error ->
        # Observe, then RE-RAISE: Oban must still fail the job and retry
        # (max_attempts: 3). Never convert a failed sweep into an :ok.
        error_class = error.__struct__ |> Module.split() |> Enum.join(".")

        Logger.error(
          "ChannelPostSweeper failed to sweep expired channel posts " <>
            "(limit=#{limit}, error_class=#{error_class}): #{Exception.message(error)}"
        )

        :telemetry.execute(
          TelemetryEvents.channel_post_sweep_exception(),
          %{count: 1},
          %{limit: limit, error_class: error_class}
        )

        reraise error, __STACKTRACE__
    end
  end

  # One bounded batch: select the expired ids (bounded by `limit`), then delete them.
  # Returns the number of rows deleted (0 when nothing is expired).
  defp sweep_batch(limit) do
    now = DateTime.utc_now()

    ids =
      ChannelPost
      |> where([p], p.expires_at < ^now)
      |> select([p], p.id)
      |> limit(^limit)
      |> AdminRepo.all()

    case ids do
      [] ->
        0

      batch_ids ->
        {count, _} =
          ChannelPost
          |> where([p], p.id in ^batch_ids)
          |> AdminRepo.delete_all()

        count
    end
  end

  # The bound is data injected via job args (not app env), so a test — or an
  # operator via a one-off job — can tune the per-run cap without config changes.
  # Clamped to @batch_size: the selected ids are passed as an explicit list to
  # `where(p.id in ^batch_ids)`, one bind parameter each, so an unbounded limit
  # >= 65536 would exceed Postgres's 65535-parameter cap and crash every retry.
  # Capping at @batch_size keeps the id-list well under the limit while still
  # letting an operator shrink the per-run cap.
  defp batch_limit(%{"limit" => limit}) when is_integer(limit) and limit > 0,
    do: min(limit, @batch_size)

  defp batch_limit(_args), do: @batch_size
end
