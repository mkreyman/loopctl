defmodule Loopctl.TenantKeys do
  @moduledoc """
  US-26.0.2 — Reads and caches tenant audit signing private keys.

  Private keys are stored in the Fly.io secret store (via the
  `Loopctl.Secrets` facade). This module caches them in an ETS table
  for 5 minutes to avoid hitting the secret store on every request.

  ## ETS table

  Created at application start (see `Loopctl.Application`). Table name
  is `:tenant_key_cache`. Entries are `{tenant_id, private_key, expires_at}`.
  """

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Secrets
  alias Loopctl.Tenants.Tenant

  @cache_table :tenant_key_cache
  @ttl_seconds 300

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

    case :ets.lookup(@cache_table, tenant_id) do
      [{^tenant_id, key, expires_at}] when expires_at > now ->
        {:ok, key}

      _ ->
        fetch_and_cache(tenant_id, now)
    end
  end

  @doc """
  Invalidate the cached key for a tenant (e.g., after key rotation).
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(tenant_id) do
    :ets.delete(@cache_table, tenant_id)
    :ok
  end

  defp fetch_and_cache(tenant_id, now) do
    import Ecto.Query

    case AdminRepo.one(from(t in Tenant, where: t.id == ^tenant_id, select: t.slug)) do
      nil ->
        {:error, :tenant_not_found}

      slug ->
        secret_name = Secrets.audit_key_secret_name(slug)

        case Secrets.get(secret_name) do
          {:ok, encoded} ->
            # Fly secrets store keys as base64 (set via FlyAdapter.set/2).
            # Decode to raw bytes for :crypto.sign/5.
            key = decode_key(encoded)
            :ets.insert(@cache_table, {tenant_id, key, now + @ttl_seconds})
            {:ok, key}

          {:error, reason} ->
            Logger.warning(
              "Failed to fetch audit key for tenant #{tenant_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
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
