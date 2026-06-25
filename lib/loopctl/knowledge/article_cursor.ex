defmodule Loopctl.Knowledge.ArticleCursor do
  @moduledoc """
  Integrity-protected, tenant-bound keyset cursor for the article list (US-27.9a).

  The article list paginates by the stable unique tuple `(inserted_at, id)` (the
  `id` tie-break is mandatory: `inserted_at` is `utc_datetime_usec` and bulk
  `insert_all` ties timestamps per batch, so `inserted_at` alone is NOT unique).
  This module turns that ordering position into an opaque string the caller hands
  back as `?cursor=`, and turns it back into the tuple on the next request.

  ## Trust model (AC-27.9a.3 / .4)

  A Base64 blob is **encoding, not integrity** — a caller can flip bits or forge a
  payload. So the cursor is treated as untrusted input:

  - It encodes ONLY an intra-tenant ordering position `(inserted_at, id)`. It does
    NOT carry the tenant_id as a trust input — the caller's tenant always comes
    from the authenticated principal (`conn.assigns`), never from the cursor.
  - It is HMAC-SHA256 signed with a PER-TENANT key derived from the app
    `secret_key_base` + the tenant_id (same server-minted scheme as
    `Loopctl.Knowledge.BulkOps.confirm_hash/2`). `decode/2` verifies with the
    CALLER's tenant key, so a cursor minted for tenant B fails verification for
    tenant A — it can neither cross tenants nor become an existence oracle for
    another tenant's rows.
  - `decode/2` is DEFENSIVE: garbage, a bit-flipped signature, a tampered payload,
    or a wrong-tenant cursor all return `{:error, :invalid}` — never a raise, and
    never a partial/ambiguous result the caller could probe with.

  The signature is compared in constant time (`:crypto.hash_equals/2`) so the
  cursor can't be brute-forced one byte at a time via timing.
  """

  @hmac_bytes 32

  @typedoc "The keyset position: the `(inserted_at, id)` of a row in (inserted_at ASC, id ASC) order."
  @type position :: {DateTime.t(), Ecto.UUID.t()}

  @doc """
  Encodes the keyset position `{inserted_at, id}` into an opaque cursor string.

  The cursor is signed with `tenant_id`'s per-tenant key. The returned string is
  URL-safe Base64 with no padding, so it is safe as a bare `?cursor=` query value.
  """
  @spec encode(Ecto.UUID.t(), position()) :: String.t()
  def encode(tenant_id, {%DateTime{} = inserted_at, id})
      when is_binary(tenant_id) and is_binary(id) do
    payload = serialize(inserted_at, id)
    sig = :crypto.mac(:hmac, :sha256, secret(tenant_id), payload)
    Base.url_encode64(payload <> sig, padding: false)
  end

  @doc """
  Decodes and verifies an opaque cursor, returning `{:ok, {inserted_at, id}}`.

  Verifies the HMAC with `tenant_id`'s per-tenant key. ANY problem — malformed
  Base64, wrong length, signature mismatch (tampered payload OR a cursor signed
  for a different tenant), or an undeserializable payload — returns
  `{:error, :invalid}`. Never raises; never leaks why it failed.
  """
  @spec decode(Ecto.UUID.t(), String.t()) :: {:ok, position()} | {:error, :invalid}
  def decode(tenant_id, cursor) when is_binary(tenant_id) and is_binary(cursor) do
    with {:ok, decoded} <- url_decode(cursor),
         {:ok, payload, sig} <- split(decoded),
         :ok <- verify(tenant_id, payload, sig) do
      deserialize(payload)
    end
  end

  def decode(_tenant_id, _cursor), do: {:error, :invalid}

  # --- internals ---

  # Canonical, fixed-shape payload: a tagged 2-tuple of the inserted_at in
  # integer microseconds (so the value is exact and order-preserving) and the
  # raw 16-byte UUID. term_to_binary is compact and round-trips precisely; we
  # never call binary_to_term WITHOUT [:safe] and we re-validate the shape, so a
  # forged payload can't deserialize into anything dangerous.
  defp serialize(%DateTime{} = inserted_at, id) do
    micros = DateTime.to_unix(inserted_at, :microsecond)
    {:ok, raw} = Ecto.UUID.dump(id)
    :erlang.term_to_binary({:k, micros, raw})
  end

  defp deserialize(payload) do
    case safe_binary_to_term(payload) do
      {:k, micros, raw}
      when is_integer(micros) and is_binary(raw) and byte_size(raw) == 16 ->
        with {:ok, datetime} <- from_unix_micros(micros),
             {:ok, id} <- Ecto.UUID.load(raw) do
          {:ok, {datetime, id}}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  # binary_to_term/2 with [:safe] still raises on a non-term binary, so guard it.
  defp safe_binary_to_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    ArgumentError -> :error
  end

  defp from_unix_micros(micros) do
    {:ok, DateTime.from_unix!(micros, :microsecond)}
  rescue
    _ -> {:error, :invalid}
  end

  defp url_decode(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid}
    end
  end

  # The trailing @hmac_bytes are the signature; everything before is the payload.
  defp split(decoded) when byte_size(decoded) > @hmac_bytes do
    payload_len = byte_size(decoded) - @hmac_bytes
    <<payload::binary-size(payload_len), sig::binary-size(@hmac_bytes)>> = decoded
    {:ok, payload, sig}
  end

  defp split(_decoded), do: {:error, :invalid}

  defp verify(tenant_id, payload, sig) do
    expected = :crypto.mac(:hmac, :sha256, secret(tenant_id), payload)

    if :crypto.hash_equals(expected, sig), do: :ok, else: {:error, :invalid}
  end

  # Per-tenant HMAC key: app secret_key_base + tenant_id. Stable across nodes
  # without storing a per-tenant secret. Mirrors BulkOps.confirm_secret/1.
  #
  # FAIL CLOSED: `secret_key_base` is fetched (not defaulted). If it were ever
  # absent, signing with a guessable constant would silently defeat the entire
  # tenant-binding/forgery guarantee (a known key + a non-secret tenant_id = a
  # forgeable cursor); raising instead is the safe failure. `runtime.exs` already
  # requires SECRET_KEY_BASE in prod and the test/dev configs set it, so this
  # raise is unreachable in every real environment — it is a guard, not a path.
  #
  # The `:article_cursor:` infix namespaces this key away from
  # `BulkOps.confirm_secret/1` and binds it to the tenant. `tenant_id` is an Ecto
  # `binary_id` (a canonical UUID), which cannot contain the `:` delimiter, so no
  # two distinct tenants can derive the same key string — no cross-tenant collision.
  defp secret(tenant_id) do
    base =
      :loopctl
      |> Application.fetch_env!(LoopctlWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    base <> ":article_cursor:" <> to_string(tenant_id)
  end
end
