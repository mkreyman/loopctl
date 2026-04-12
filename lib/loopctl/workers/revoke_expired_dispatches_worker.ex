defmodule Loopctl.Workers.RevokeExpiredDispatchesWorker do
  @moduledoc """
  US-26.2.1 — Revokes dispatches (and their api_keys) past expiry.
  Runs every minute via Oban Cron.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
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

    AdminRepo.transaction(fn ->
      {d_count, _} =
        from(d in Dispatch, where: d.id in ^dispatch_ids)
        |> AdminRepo.update_all(set: [revoked_at: now])

      revoke_keys(key_ids, now)

      Logger.info("RevokeExpiredDispatchesWorker: revoked #{d_count} expired dispatches")
    end)
  end

  defp revoke_keys([], _now), do: :ok

  defp revoke_keys(key_ids, now) do
    from(k in ApiKey, where: k.id in ^key_ids and is_nil(k.revoked_at))
    |> AdminRepo.update_all(set: [revoked_at: now])
  end
end
