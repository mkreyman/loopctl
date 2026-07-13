defmodule Loopctl.Workers.RevokeExpiredDispatchesWorker do
  @moduledoc """
  US-26.2.1 — Revokes dispatches (and their api_keys) past expiry.
  Runs every minute via Oban Cron.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Dispatches.Dispatch

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find expired, non-revoked dispatches
    expired =
      from(d in Dispatch,
        where: is_nil(d.revoked_at) and d.expires_at < ^now,
        select: %{id: d.id, api_key_id: d.api_key_id}
      )
      |> AdminRepo.all()

    if expired != [] do
      revoke_expired_batch(expired, now)
    end

    :ok
  end

  defp revoke_expired_batch(expired, now) do
    dispatch_ids = Enum.map(expired, & &1.id)
    key_ids = expired |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1)

    result =
      AdminRepo.transaction(fn ->
        {d_count, _} =
          from(d in Dispatch, where: d.id in ^dispatch_ids)
          |> AdminRepo.update_all(set: [revoked_at: now])

        key_hashes = revoke_keys(key_ids, now)

        Logger.info("RevokeExpiredDispatchesWorker: revoked #{d_count} expired dispatches")

        key_hashes
      end)

    # SECURITY (AC-33.3.2): the update_all cascade bypasses changesets, so bust the
    # api-key cache explicitly for every revoked key_hash AFTER commit. The hashes
    # came back from the revoke statement itself (`select: k.key_hash`), so no
    # second AdminRepo lookup competes for the pool this cache relieves (US-33.3,
    # finding-4 remediation).
    case result do
      {:ok, key_hashes} -> Auth.invalidate_key_cache_by_hashes(key_hashes)
      _ -> :ok
    end

    result
  end

  defp revoke_keys([], _now), do: []

  defp revoke_keys(key_ids, now) do
    {_count, key_hashes} =
      from(k in ApiKey,
        where: k.id in ^key_ids and is_nil(k.revoked_at),
        select: k.key_hash
      )
      |> AdminRepo.update_all(set: [revoked_at: now])

    key_hashes
  end
end
