defmodule Loopctl.Workers.ReauthChallengeCleanupWorker do
  @moduledoc """
  crypto-01 (GHSA-c3cw-5f7p-g76r) / US-26.7.2 — Oban worker that periodically
  deletes stale WebAuthn challenges from BOTH:

    * `webauthn_reauth_challenges` (`Loopctl.WebAuthn.ReauthChallenge`) — the
      audit-key-rotation and authenticator-revoke reauth ceremonies.
    * `webauthn_enrollment_challenges` (`Loopctl.WebAuthn.EnrollmentChallenge`,
      US-26.7.2) — the registration-challenge store backing the opt-in
      agent_rooted -> human_anchored trust-tier upgrade ceremony.

  Both tables share the exact same single-use/TTL persistence shape and
  cleanup cadence, so one worker sweeps both rather than duplicating an
  almost-identical cron job and Oban queue entry.

  Runs hourly via the Oban Cron plugin. Deletes every challenge past its
  `expires_at` (which includes consumed ones, since a consumed challenge is
  still TTL-bounded) from each table to prevent unbounded growth.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WebAuthn.EnrollmentChallenge
  alias Loopctl.WebAuthn.ReauthChallenge

  @impl Oban.Worker
  def perform(_job) do
    reauth_deleted = purge_stale(ReauthChallenge)
    enrollment_deleted = purge_stale(EnrollmentChallenge)
    total = reauth_deleted + enrollment_deleted

    if total > 0 do
      require Logger

      Logger.info(
        "ReauthChallengeCleanupWorker deleted #{reauth_deleted} stale reauth challenge(s) " <>
          "and #{enrollment_deleted} stale enrollment challenge(s)"
      )
    end

    :ok
  end

  defp purge_stale(schema) do
    now = DateTime.utc_now()

    {deleted_count, _} =
      from(c in schema, where: c.expires_at < ^now or not is_nil(c.used_at))
      |> AdminRepo.delete_all()

    deleted_count
  end
end
