defmodule Loopctl.Auth do
  @moduledoc """
  Context module for authentication and API key management.

  API keys are the sole authentication mechanism. Raw keys are generated
  with a `lc_` prefix followed by 40 URL-safe base64 characters. Only
  the SHA-256 hash is stored; the raw key is visible once at creation.

  ## Key generation

  1. Generate random bytes and encode as URL-safe base64
  2. Prepend the `lc_` prefix
  3. Store SHA-256 hash of the full key
  4. Store first 8 characters as `key_prefix` for identification

  ## Verification

  1. Hash the provided raw key with SHA-256
  2. Look up by `key_hash`
  3. Reject if revoked or expired
  4. Update `last_used_at` on success
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache

  @key_prefix "lc_"
  @random_bytes 30

  @doc """
  Generates a new API key and persists the hashed version.

  Returns `{:ok, {raw_key, %ApiKey{}}}` on success.
  The raw key is the only time the plaintext key is available.

  ## Parameters

  - `attrs` — must include `:name` and `:role`. For non-superadmin keys,
    `:tenant_id` must be set in the attrs (it is applied programmatically).
  """
  @spec generate_api_key(map()) :: {:ok, {String.t(), ApiKey.t()}} | {:error, Ecto.Changeset.t()}
  def generate_api_key(attrs) do
    raw_key = generate_raw_key()
    key_hash = hash_key(raw_key)
    key_prefix = String.slice(raw_key, 0, 8)

    tenant_id = Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id")

    # Set tenant_id on the struct before changeset so validation can see it
    base = if tenant_id, do: %ApiKey{tenant_id: tenant_id}, else: %ApiKey{}

    changeset =
      base
      |> ApiKey.create_changeset(attrs)
      |> Ecto.Changeset.put_change(:key_hash, key_hash)
      |> Ecto.Changeset.put_change(:key_prefix, key_prefix)

    case AdminRepo.insert(changeset) do
      {:ok, api_key} ->
        # A brand-new key_hash has nothing cached, but invalidate defensively to
        # cover the (astronomically unlikely) re-created-hash path and to keep the
        # rule "every key writer busts its key_hash" uniform (AC-33.3.3).
        ApiKeyCache.invalidate_cluster(api_key.key_hash)
        {:ok, {raw_key, api_key}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Verifies a raw API key by hashing it and looking up the hash.

  Returns `{:ok, %ApiKey{}}` with preloaded tenant on success.
  Returns `{:error, :unauthorized}` if the key is not found, revoked, or expired.

  READ-THROUGH CACHED (US-33.3): the resolved `%ApiKey{}` (with `:tenant`
  preloaded) is served from a supervised ETS cache keyed by `key_hash`,
  converting a per-request AdminRepo SELECT into a per-change one. On a HIT the
  SQL `revoked_at`/`expires_at` guards are no longer applied, so they are
  re-enforced against wall-clock now on the cached struct (`valid_now?/1`,
  AC-33.3.5) — a cached-but-now-expired/revoked key is rejected exactly like an
  uncached one. On a MISS the generation is captured BEFORE the DB load and
  passed to `put/3`, so a revoke/rotation that invalidates during the load is
  detected and the repopulation rejected (never serve a revoked key). Every
  revoke/rotate/mutate writer invalidates the `key_hash` entry in-band, with a
  bounded TTL as the defense-in-depth backstop. See `Loopctl.Auth.ApiKeyCache`.

  The per-request `last_used_at` UPDATE still fires on every request — this
  story removes ONLY the SELECT (AC-33.3.6; US-33.4 owns debouncing the write).
  """
  @spec verify_api_key(String.t()) :: {:ok, ApiKey.t()} | {:error, :unauthorized}
  def verify_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    case ApiKeyCache.fetch(key_hash) do
      {:ok, %ApiKey{} = api_key} ->
        # HIT: the SQL guards were not applied, so re-enforce revoked_at/
        # expires_at against wall-clock now before trusting the cached struct.
        if valid_now?(api_key),
          do: verify_and_touch(api_key, key_hash),
          else: {:error, :unauthorized}

      :miss ->
        # Capture the generation BEFORE the DB read so a concurrent invalidation
        # rejects this (possibly stale) repopulation at the next fetch/1.
        generation = ApiKeyCache.generation(key_hash)

        case load_active_api_key(key_hash) do
          nil ->
            {:error, :unauthorized}

          api_key ->
            # Cache only POSITIVE resolutions (the SQL guards already excluded
            # revoked/expired rows), so a revoked/expired key is never cached.
            ApiKeyCache.put(key_hash, api_key, generation)
            verify_and_touch(api_key, key_hash)
        end
    end
  end

  # Uncached DB read of the ACTIVE (non-revoked, non-expired) api_key for a hash,
  # with :tenant preloaded (custody_halted_at). Mirrors the guards that make a
  # cache HIT safe to re-enforce in `valid_now?/1`.
  defp load_active_api_key(key_hash) do
    query =
      from ak in ApiKey,
        where: ak.key_hash == ^key_hash,
        where: is_nil(ak.revoked_at),
        where: is_nil(ak.expires_at) or ak.expires_at > ^DateTime.utc_now(),
        preload: [:tenant]

    AdminRepo.one(query)
  end

  # Re-enforces the SQL WHERE guards on a cache HIT: active iff not revoked AND
  # (no expiry OR expiry still in the future).
  defp valid_now?(%ApiKey{revoked_at: revoked_at}) when not is_nil(revoked_at), do: false
  defp valid_now?(%ApiKey{expires_at: nil}), do: true

  defp valid_now?(%ApiKey{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp verify_and_touch(api_key, key_hash) do
    # Constant-time comparison to prevent timing-based side channels.
    # Both sides are SHA-256 hex strings of equal length.
    if Plug.Crypto.secure_compare(api_key.key_hash, key_hash) do
      case update_last_used(api_key) do
        {:ok, updated} -> {:ok, updated}
        _error -> {:ok, api_key}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Revokes an API key by setting `revoked_at` to now.
  """
  @spec revoke_api_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.revoke_changeset()
    |> AdminRepo.update()
    |> tap_invalidate(api_key.key_hash)
  end

  # SECURITY (AC-33.3.2/.3): bust the cached entry for this key_hash the moment a
  # revoke/rotate write commits, cluster-wide, so the very next request re-loads
  # read-through (and the wall-clock guards reject a revoked/expired key) instead
  # of serving the stale cached struct until the TTL.
  defp tap_invalidate({:ok, _} = result, key_hash) do
    ApiKeyCache.invalidate_cluster(key_hash)
    result
  end

  defp tap_invalidate(other, _key_hash), do: other

  @doc """
  Busts the api-key cache entry for each api_key id in `ids`, cluster-wide.

  For the cascade writers (`Loopctl.Dispatches.revoke/2`, the expired-dispatch
  worker, agent binding) that mutate/revoke keys via `update_all` or by id and do
  NOT have the `key_hash` in hand — the caches are keyed by `key_hash`, so this
  resolves the hashes for the given ids and invalidates each (US-33.3).
  """
  @spec invalidate_key_cache_by_ids([Ecto.UUID.t()]) :: :ok
  def invalidate_key_cache_by_ids([]), do: :ok

  def invalidate_key_cache_by_ids(ids) when is_list(ids) do
    from(ak in ApiKey, where: ak.id in ^ids, select: ak.key_hash)
    |> AdminRepo.all()
    |> Enum.each(&ApiKeyCache.invalidate_cluster/1)
  end

  @doc """
  Busts the api-key cache for ALL of a tenant's keys, cluster-wide.

  The cache stores each api_key WITH its `:tenant` preloaded (carrying
  authorization-relevant tenant fields: `status`, `custody_halted_at`,
  `trust_tier` — read by `ResolveApiKey`, `CheckCustodyHalt`, and
  `RequireHumanAnchor`). A tenant-row mutation therefore leaves those cached
  snapshots stale, so every tenant-auth mutation (suspend/activate, custody
  halt/clear, WebAuthn trust-tier upgrade, audit-key rotation) calls this so the
  change takes effect on the very next request rather than after the TTL
  (US-33.3, composes with US-33.2).
  """
  @spec invalidate_tenant_key_cache(Ecto.UUID.t()) :: :ok
  def invalidate_tenant_key_cache(tenant_id) when is_binary(tenant_id) do
    from(ak in ApiKey, where: ak.tenant_id == ^tenant_id, select: ak.key_hash)
    |> AdminRepo.all()
    |> Enum.each(&ApiKeyCache.invalidate_cluster/1)
  end

  @doc """
  Lists API keys for a given tenant.

  Options:
  - `:include_revoked` — when `true`, includes revoked keys (default: `false`)
  """
  @spec list_api_keys(Ecto.UUID.t(), keyword()) :: {:ok, [ApiKey.t()]}
  def list_api_keys(tenant_id, opts \\ []) do
    include_revoked = Keyword.get(opts, :include_revoked, false)

    query =
      from ak in ApiKey,
        where: ak.tenant_id == ^tenant_id,
        order_by: [desc: ak.inserted_at]

    query =
      if include_revoked do
        query
      else
        where(query, [ak], is_nil(ak.revoked_at))
      end

    {:ok, AdminRepo.all(query)}
  end

  @doc """
  Gets an API key by ID, scoped to a tenant.
  """
  @spec get_api_key(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, ApiKey.t()} | {:error, :not_found}
  def get_api_key(tenant_id, key_id) do
    query =
      from ak in ApiKey,
        where: ak.id == ^key_id and ak.tenant_id == ^tenant_id

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      api_key -> {:ok, api_key}
    end
  end

  @doc """
  Counts active (non-revoked) API keys for a tenant.
  """
  @spec count_api_keys(Ecto.UUID.t()) :: non_neg_integer()
  def count_api_keys(tenant_id) do
    from(ak in ApiKey,
      where: ak.tenant_id == ^tenant_id and is_nil(ak.revoked_at),
      select: count(ak.id)
    )
    |> AdminRepo.one()
  end

  @doc """
  Sets the expires_at on an API key (used during rotation).
  """
  @spec expire_api_key(ApiKey.t(), DateTime.t()) ::
          {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def expire_api_key(%ApiKey{} = api_key, expires_at) do
    api_key
    |> ApiKey.expire_changeset(expires_at)
    |> AdminRepo.update()
    |> tap_invalidate(api_key.key_hash)
  end

  @doc """
  Generates a raw API key string.

  Format: `lc_` + 40 URL-safe base64 characters (from 30 random bytes).
  """
  @spec generate_raw_key() :: String.t()
  def generate_raw_key do
    random = :crypto.strong_rand_bytes(@random_bytes) |> Base.url_encode64(padding: false)
    @key_prefix <> random
  end

  @doc """
  Computes the SHA-256 hash of a raw key, returned as lowercase hex.
  """
  @spec hash_key(String.t()) :: String.t()
  def hash_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  defp update_last_used(api_key) do
    api_key
    |> ApiKey.touch_changeset()
    |> AdminRepo.update()
  end
end
