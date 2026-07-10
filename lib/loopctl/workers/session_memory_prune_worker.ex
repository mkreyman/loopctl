defmodule Loopctl.Workers.SessionMemoryPruneWorker do
  @moduledoc """
  Oban cron worker that prunes expired short-term session memories
  (`Loopctl.Memory.SessionMemory`), Epic 28 / US-28.2.

  The short-term tier is deliberately bounded (per #307): every row carries an
  `expires_at`, and this worker deletes rows past it. Scheduled via the Oban Cron
  plugin in `config/config.exs` (every 5 minutes), following the existing
  cleanup-worker convention (see `Loopctl.Workers.WebhookCleanupWorker`).

  Expiry is a uniform, tenant-independent predicate (`expires_at < now()`), so the
  delete runs once across all tenants on the BYPASSRLS `Loopctl.AdminRepo`.
  Deletions are batched (1000 per iteration) to avoid a long-running transaction.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Memory.SessionMemory

  @batch_size 1000

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    deleted = delete_in_batches(now, 0)

    if deleted > 0 do
      Logger.info("SessionMemoryPruneWorker pruned #{deleted} expired session memories")
    end

    :ok
  end

  defp delete_in_batches(now, total_deleted) do
    ids =
      SessionMemory
      |> where([s], s.expires_at < ^now)
      |> select([s], s.id)
      |> limit(@batch_size)
      |> AdminRepo.all()

    case ids do
      [] ->
        total_deleted

      batch_ids ->
        {count, _} =
          SessionMemory
          |> where([s], s.id in ^batch_ids)
          |> AdminRepo.delete_all()

        delete_in_batches(now, total_deleted + count)
    end
  end
end
