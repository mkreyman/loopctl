defmodule Loopctl.Workers.BulkDeleteTokenCleanupWorker do
  @moduledoc """
  Oban worker that periodically deletes expired bulk delete tokens.

  Runs hourly via the Oban Cron plugin. Deletes all tokens where
  `expires_at < now()` to prevent unbounded table growth.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.BulkDeleteToken

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    {deleted_count, _} =
      from(t in BulkDeleteToken, where: t.expires_at < ^now)
      |> AdminRepo.delete_all()

    if deleted_count > 0 do
      require Logger
      Logger.info("BulkDeleteTokenCleanupWorker deleted #{deleted_count} expired tokens")
    end

    :ok
  end
end
