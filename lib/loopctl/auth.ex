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
      {:ok, api_key} -> {:ok, {raw_key, api_key}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verifies a raw API key by hashing it and looking up the hash.

  Returns `{:ok, %ApiKey{}}` with preloaded tenant on success.
  Returns `{:error, :unauthorized}` if the key is not found, revoked, or expired.
  """
  @spec verify_api_key(String.t()) :: {:ok, ApiKey.t()} | {:error, :unauthorized}
  def verify_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from ak in ApiKey,
        where: ak.key_hash == ^key_hash,
        where: is_nil(ak.revoked_at),
        where: is_nil(ak.expires_at) or ak.expires_at > ^DateTime.utc_now(),
        preload: [:tenant]

    case AdminRepo.one(query) do
      nil -> {:error, :unauthorized}
      api_key -> verify_and_touch(api_key, key_hash)
    end
  end

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
