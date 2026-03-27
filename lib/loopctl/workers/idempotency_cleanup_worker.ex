defmodule Loopctl.Workers.IdempotencyCleanupWorker do
  @moduledoc """
  Oban worker that periodically deletes expired idempotency cache entries.

  Runs hourly via the Oban Cron plugin. Deletes all entries where
  `expires_at < now()` to prevent unbounded table growth.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.IdempotencyCache

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    {deleted_count, _} =
      from(ic in IdempotencyCache, where: ic.expires_at < ^now)
      |> AdminRepo.delete_all()

    if deleted_count > 0 do
      require Logger
      Logger.info("IdempotencyCleanupWorker deleted #{deleted_count} expired entries")
    end

    :ok
  end
end
