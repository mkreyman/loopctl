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
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost

  @batch_size 1000

  @doc """
  Deletes at most one batch of expired channel posts (`expires_at < now()`).

  Reads the `"limit"` job arg (a positive integer) as the per-run batch bound,
  defaulting to `#{@batch_size}`. Returns `:ok` whether or not anything was
  deleted (idempotent); logs the count only when it is positive.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: args}) do
    now = DateTime.utc_now()
    limit = batch_limit(args)

    ids =
      ChannelPost
      |> where([p], p.expires_at < ^now)
      |> select([p], p.id)
      |> limit(^limit)
      |> AdminRepo.all()

    case ids do
      [] ->
        :ok

      batch_ids ->
        {count, _} =
          ChannelPost
          |> where([p], p.id in ^batch_ids)
          |> AdminRepo.delete_all()

        if count > 0 do
          Logger.info("ChannelPostSweeper deleted #{count} expired channel posts")
        end

        :ok
    end
  end

  # The bound is data injected via job args (not app env), so a test — or an
  # operator via a one-off job — can tune the per-run cap without config changes.
  defp batch_limit(%{"limit" => limit}) when is_integer(limit) and limit > 0, do: limit
  defp batch_limit(_args), do: @batch_size
end
