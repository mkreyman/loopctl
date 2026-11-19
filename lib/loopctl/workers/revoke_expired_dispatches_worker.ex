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
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake.Source

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find expired, non-revoked dispatches. CROSS-TENANT by design — this is a sweep, so
    # `tenant_id` comes back on every row and the write below is grouped by it.
    #
    # A chg ROOT that a live intake source names is never a candidate: its row is a lineage
    # anchor that the source's every ledger post, change event and reviewer mint is judged
    # against (`Loopctl.Intake`'s `chg_root?/1` requires `revoked_at IS NULL`), and it outlives
    # the 4h dispatch ceiling by design. Revoking it on expiry turned every chg enrolment into
    # a 4h credential that nothing could renew. Its KEY, if an operator minted it with one, is
    # still revoked: only the row is exempt. A root no live source names any more (the source
    # revoked or repointed) is swept as before.
    expired =
      from(d in Dispatch,
        where: is_nil(d.revoked_at) and d.expires_at < ^now,
        select: %{id: d.id, tenant_id: d.tenant_id, api_key_id: d.api_key_id}
      )
      |> AdminRepo.all()
      |> mark_named_roots()

    if expired != [] do
      revoke_expired_batch(expired, now)
    end

    :ok
  end

  # THE WRITE RE-ASSERTS `revoked_at IS NULL`, and it does so by calling
  # `Dispatches.revoke_dispatch_rows/3` rather than restating the predicate here — one
  # definition, so the two sweeps cannot drift apart again (#862 review round 3, finding 2).
  #
  # The candidate read above runs OUTSIDE this transaction and is ADVISORY. Under READ
  # COMMITTED a `force_unclaim` can revoke one of these rows between the read and this write
  # and append a `dispatch_revoked` entry naming that timestamp; without the predicate this
  # UPDATE then rewrites `revoked_at` to a LATER value, and the row permanently contradicts an
  # immutable, STH-covered chain entry that nobody can correct.
  #
  # Grouped by tenant because `revoke_dispatch_rows/3` scopes its write to one: this runs on
  # `AdminRepo` (BYPASSRLS), where the explicit predicate is the only isolation there is. It
  # costs one statement per tenant with expiring dispatches in this minute, inside the one
  # transaction the batch already had.
  #
  # What this sweep still does NOT do, deliberately and unchanged: it appends no
  # `dispatch_revoked` chain entry. Expiry is the credential's own TTL elapsing rather than a
  # principal revoking anything, so there is no actor to name on such an entry.
  defp revoke_expired_batch(expired, now) do
    # Every expired KEY is revoked, a named chg root's included; only the named root's ROW is
    # kept (see the candidate read). Such a row stays a candidate on every run, and the key
    # write is idempotent on it (`is_nil(k.revoked_at)`).
    key_ids = expired |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1)

    by_tenant =
      expired
      |> Enum.reject(& &1.named_root?)
      |> Enum.group_by(& &1.tenant_id, & &1.id)

    result =
      AdminRepo.transaction(fn ->
        d_count =
          Enum.reduce(by_tenant, 0, fn {tenant_id, dispatch_ids}, acc ->
            acc + Dispatches.revoke_dispatch_rows(tenant_id, dispatch_ids, now)
          end)

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

  # By tenant AND id: the read runs on `AdminRepo` (BYPASSRLS), so the source's tenant is
  # matched explicitly. Never another tenant's source exempting this tenant's row.
  defp mark_named_roots([]), do: []

  defp mark_named_roots(expired) do
    ids = Enum.map(expired, & &1.id)

    named =
      from(s in Source,
        where: s.chg_root_dispatch_id in ^ids and is_nil(s.revoked_at),
        select: {s.tenant_id, s.chg_root_dispatch_id}
      )
      |> AdminRepo.all()
      |> MapSet.new()

    Enum.map(expired, &Map.put(&1, :named_root?, MapSet.member?(named, {&1.tenant_id, &1.id})))
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
