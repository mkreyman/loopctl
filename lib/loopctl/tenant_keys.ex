defmodule Loopctl.TenantKeys do
  @moduledoc """
  US-26.0.2 — Reads and caches tenant audit signing private keys.

  Private keys are stored in the Fly.io secret store (via the
  `Loopctl.Secrets` facade). This module caches them in an ETS table
  for 5 minutes to avoid hitting the secret store on every request.

  ## ETS table

  Created at application start (see `Loopctl.Application`). Table name is
  `:tenant_key_cache`. Entries are `{tenant_id, result, expires_at, epoch}` — the
  `{:ok, key}` / `{:error, reason}` returned, failures included on a short TTL.
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Secrets
  alias Loopctl.Tenants.Tenant

  @cache_table :tenant_key_cache
  @ttl_seconds 300

  # Failures are cached because the caller that hurts most repeats: `verifier_seed/2` asks on
  # EVERY request-review, so an uncached miss costs an AdminRepo query (a deliberately
  # 3-connection pool) plus a secret-store trip, per call — `:not_found` most of all, since a
  # tenant with no audit key yet answers it for as long as it has none, a PERMANENT storm.
  # The TTL is short so a resolved outage, or a key just written, is not extended into
  # spurious `verifier_needed`; a path that WRITES a key calls `invalidate/1`, not the TTL.
  @negative_ttl_seconds 15

  @doc """
  Ensure the ETS cache table exists. Called from `Application.start/2`.
  """
  @spec init_cache() :: :ok
  def init_cache do
    # Public access: rotation runs in request processes that need to
    # invalidate cache entries. A GenServer wrapper would be cleaner
    # but adds complexity for a cache that only holds ephemeral data.
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Get the ed25519 private key for a tenant. Checks the ETS cache first;
  falls through to the secret store on miss or expiry.

  Returns `{:ok, private_key_bytes}` or `{:error, reason}`.
  """
  @spec get_private_key(Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def get_private_key(tenant_id) when is_binary(tenant_id) do
    now = System.system_time(:second)
    epoch = epoch(tenant_id)

    case :ets.lookup(@cache_table, tenant_id) do
      [{^tenant_id, result, expires_at, ^epoch}] when expires_at > now -> result
      _ -> fetch_and_cache(tenant_id, now, epoch)
    end
  end

  @doc """
  Invalidate the cached key for a tenant (after key rotation or provisioning).
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(tenant_id) do
    key = {:epoch, tenant_id}
    :ets.update_counter(@cache_table, key, {2, 1}, {key, 0})
    :ets.delete(@cache_table, tenant_id)
    :ok
  end

  # Invalidation must cover a fetch already IN FLIGHT: deleting the row is not enough, because
  # a slow fetch that began before a rotation and fails after it lands on the empty table and
  # poisons the freshly rotated key for the negative TTL. An entry carries the epoch it was
  # fetched under and a read takes only its own, so one bump orphans them all.
  defp epoch(tenant_id), do: :ets.lookup_element(@cache_table, {:epoch, tenant_id}, 2, 0)

  defp fetch_and_cache(tenant_id, now, epoch) do
    import Ecto.Query

    case AdminRepo.one(from(t in Tenant, where: t.id == ^tenant_id, select: t.slug)) do
      nil ->
        cache_negative(tenant_id, {:error, :tenant_not_found}, now, epoch)

      slug ->
        secret_name = Secrets.audit_key_secret_name(slug)

        case Secrets.get(secret_name) do
          {:ok, encoded} ->
            # Fly secrets store keys as base64 (set via FlyAdapter.set/2).
            # Decode to raw bytes for :crypto.sign/5.
            key = decode_key(encoded)
            :ets.insert(@cache_table, {tenant_id, {:ok, key}, now + @ttl_seconds, epoch})
            {:ok, key}

          {:error, reason} ->
            Logger.warning(
              "Failed to fetch audit key for tenant #{tenant_id}: #{inspect(reason)}"
            )

            cache_negative(tenant_id, {:error, reason}, now, epoch)
        end
    end
  end

  # A failure must never overwrite a LIVE positive entry — a slow error can land after a
  # concurrent success. `select_replace` tests "non-positive or already expired" and writes in
  # ONE atomic op (lookup-then-insert leaves a window); it matches nothing when the row is
  # absent, so `insert_new` covers that without clobbering a racing writer.
  defp cache_negative(tenant_id, result, now, epoch) do
    entry = {tenant_id, result, now + @negative_ttl_seconds, epoch}
    stale = {:orelse, {:"/=", {:element, 1, :"$1"}, :ok}, {:"=<", :"$2", now}}
    ms = [{{tenant_id, :"$1", :"$2", :_}, [stale], [{:const, entry}]}]

    if :ets.select_replace(@cache_table, ms) == 0, do: :ets.insert_new(@cache_table, entry)

    result
  end

  # Keys may be stored as base64 (FlyAdapter encodes) or raw bytes (test mocks).
  # Try base64 decode first; if it fails, assume raw bytes.
  defp decode_key(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, raw} when byte_size(raw) == 32 -> raw
      _ -> value
    end
  end
end
