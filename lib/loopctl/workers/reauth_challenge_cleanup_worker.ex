defmodule Loopctl.Workers.ReauthChallengeCleanupWorker do
  @moduledoc """
  crypto-01 — Oban worker that periodically deletes stale WebAuthn reauth
  challenges.

  Runs hourly via the Oban Cron plugin. Deletes every challenge past its
  `expires_at` (which includes consumed ones, since a consumed challenge is
  still TTL-bounded) to prevent unbounded table growth.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn.ReauthChallenge

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    {deleted_count, _} =
      from(c in ReauthChallenge, where: c.expires_at < ^now or not is_nil(c.used_at))
      |> AdminRepo.delete_all()

    if deleted_count > 0 do
      require Logger
      Logger.info("ReauthChallengeCleanupWorker deleted #{deleted_count} stale challenges")
    end

    :ok
  end
end
