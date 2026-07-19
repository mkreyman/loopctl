defmodule Loopctl.KeysetCursor do
  @moduledoc """
  Shared, integrity-protected, tenant-bound keyset cursor codec (US-27.9a / US-27.9b).

  This is the SINGLE implementation of the security-critical cursor codec used by
  every keyset enumeration in loopctl. Each enumeration binds its own `namespace`
  (e.g. `"article_cursor"`, `"changes_cursor"`) so a cursor minted for one surface
  CANNOT be replayed against another — the per-tenant HMAC key derivation folds the
  namespace in, so the signatures differ even for the same tenant + position. Thin
  per-surface delegators (`Loopctl.Knowledge.ArticleCursor`,
  `Loopctl.Audit.ChangesCursor`) bind their namespace and forward here.

  A keyset position is a stable unique tuple `(inserted_at, tiebreak)`. The
  tiebreak is mandatory: `inserted_at` is `utc_datetime_usec` and bulk
  `insert_all` / `Ecto.Multi` ties timestamps, so `inserted_at` alone is NOT unique
  and a page boundary could skip or duplicate tied rows. This module turns that
  ordering position into an opaque string the caller hands back as `?cursor=`, and
  turns it back into the tuple on the next request.

  ## Tiebreak: UUID or monotonic integer (US-40.C2)

  Two shapes of tiebreak are supported, and the codec is bijective for BOTH:

  - A `binary_id` **UUID** (`Ecto.UUID.t()`) — the original shape, used where the
    table's stable tie-break is its random `id` (article list, change feed). The
    payload embeds the raw 16-byte UUID.
  - A **monotonic integer** — used by the repo Coordination Bus (`channel_posts`),
    whose newest-first read tie-breaks on the `seq` bigserial column (strictly
    increasing with insert order) rather than a random v4 `id`. Keyset paging on
    `(inserted_at, id)` there would be non-deterministic because `id` carries no
    order; `(inserted_at, seq)` is the correct deterministic keyset. The integer
    rides under a DISTINCT tag (so a UUID cursor and an integer cursor never
    deserialize into each other) and is AEAD-ENCRYPTED inside the payload (see
    below).

  Both shapes ride the SAME HMAC/tamper/cross-tenant/cross-namespace discipline —
  the tiebreak lives inside the signed payload, so an integer cursor is exactly as
  forge-resistant and tenant-bound as a UUID one.

  ## Confidentiality of the integer tiebreak (US-40.C2 review fix)

  The HMAC makes the cursor UNFORGEABLE, but unforgeable is not the same as
  UNREADABLE: a `Base64(term_to_binary(...) <> hmac)` blob is plaintext the holder
  can decode and read. That is harmless for the UUID tiebreak (a random v4 `id`
  reveals nothing), but the `seq` bigserial is a GLOBAL, cross-tenant counter — a
  tenant that could read the raw `seq` from two of its own cursors could diff them
  to infer the aggregate volume of OTHER tenants' `channel_posts` inserts in
  between, a cross-tenant activity side channel on an RLS-isolated platform. So the
  integer tiebreak is AES-256-GCM encrypted under a per-tenant, per-namespace key
  (with a fresh random IV per encode, making the whole cursor non-deterministic)
  BEFORE it enters the payload; only the server, holding the tenant key, decrypts it
  back to the real `seq` to run the keyset walk. The random-UUID tiebreak stays in
  plaintext — encrypting it would break in-flight article/changes cursors for no
  security gain.

  ## Trust model (AC-27.9a.3/.4, AC-27.9b.4)

  A Base64 blob is **encoding, not integrity** — a caller can flip bits or forge a
  payload. So the cursor is treated as untrusted input:

  - It encodes ONLY an intra-tenant ordering position `(inserted_at, id)`. It does
    NOT carry the tenant_id as a trust input — the caller's tenant always comes from
    the authenticated principal (`conn.assigns`), never from the cursor.
  - It is HMAC-SHA256 signed with a PER-TENANT, PER-NAMESPACE key derived from the
    app `secret_key_base` + the namespace + the tenant_id. `decode/3` verifies with
    the CALLER's tenant key under the SAME namespace, so a cursor minted for tenant B
    (or for a different namespace) fails verification — it can neither cross tenants
    nor cross enumeration surfaces, nor become an existence oracle for another
    tenant's rows.
  - `decode/3` is DEFENSIVE: garbage, a bit-flipped signature, a tampered payload, a
    wrong-tenant cursor, or a wrong-namespace cursor all return `{:error, :invalid}`
    — never a raise, and never a partial/ambiguous result the caller could probe with.

  The signature is compared in constant time (`:crypto.hash_equals/2`) so the cursor
  can't be brute-forced one byte at a time via timing.
  """

  @hmac_bytes 32

  @typedoc """
  The keyset position: the `(inserted_at, tiebreak)` of a row, where `tiebreak` is
  either the row's `binary_id` UUID (inserted_at ASC, id ASC order) or a monotonic
  integer such as a `seq` bigserial (inserted_at DESC, seq DESC order).
  """
  @type position :: {DateTime.t(), Ecto.UUID.t() | integer()}

  @doc """
  Encodes the keyset position `{inserted_at, tiebreak}` into an opaque cursor
  string, signed with `namespace`'s per-tenant key. `tiebreak` is either a
  `binary_id` UUID (string) or a monotonic integer (e.g. a `seq` bigserial).

  The returned string is URL-safe Base64 with no padding, so it is safe as a bare
  `?cursor=` query value.
  """
  @spec encode(String.t(), Ecto.UUID.t(), position()) :: String.t()
  def encode(namespace, tenant_id, {%DateTime{} = inserted_at, tiebreak})
      when is_binary(namespace) and is_binary(tenant_id) and
             (is_binary(tiebreak) or is_integer(tiebreak)) do
    payload = serialize(namespace, tenant_id, inserted_at, tiebreak)
    sig = :crypto.mac(:hmac, :sha256, secret(namespace, tenant_id), payload)
    Base.url_encode64(payload <> sig, padding: false)
  end

  @doc """
  Decodes and verifies an opaque cursor, returning `{:ok, {inserted_at, tiebreak}}`.

  Verifies the HMAC with `namespace`'s per-tenant key. ANY problem — malformed
  Base64, wrong length, signature mismatch (tampered payload, a cursor signed for a
  different tenant, OR a cursor signed for a different namespace), or an
  undeserializable payload — returns `{:error, :invalid}`. Never raises; never leaks
  why it failed.
  """
  @spec decode(String.t(), Ecto.UUID.t(), String.t()) :: {:ok, position()} | {:error, :invalid}
  def decode(namespace, tenant_id, cursor)
      when is_binary(namespace) and is_binary(tenant_id) and is_binary(cursor) do
    with {:ok, decoded} <- url_decode(cursor),
         {:ok, payload, sig} <- split(decoded),
         :ok <- verify(namespace, tenant_id, payload, sig) do
      deserialize(namespace, tenant_id, payload)
    end
  end

  def decode(_namespace, _tenant_id, _cursor), do: {:error, :invalid}

  # --- internals ---

  # Canonical, fixed-shape payload: a tagged tuple of the inserted_at in integer
  # microseconds (so the value is exact and order-preserving) and the tiebreak.
  # term_to_binary is compact and round-trips precisely; we never call
  # binary_to_term WITHOUT [:safe] and we re-validate the shape, so a forged payload
  # can't deserialize into anything dangerous.
  #
  # Two tags keep the shapes disjoint so a UUID cursor and an integer cursor can
  # never deserialize into each other:
  #   {:k, micros, raw16}          → UUID tiebreak (raw 16-byte binary_id)
  #   {:kie, micros, iv, ct, tag}  → integer tiebreak (e.g. a `seq` bigserial),
  #                                  ENCRYPTED (see below)
  #
  # CONFIDENTIALITY of the integer tiebreak (US-40.C2 review fix): a `seq` bigserial
  # is a GLOBAL, cross-tenant counter. The HMAC makes the cursor unforgeable, but
  # unforgeable != unreadable — a Base64 + `term_to_binary` payload is plaintext the
  # holder can `binary_to_term` and read. Emitting the raw `seq` would let any tenant
  # diff the `seq` between two of its own reads and infer the aggregate volume of
  # OTHER tenants' `channel_posts` inserts in between — a cross-tenant activity side
  # channel on an RLS-isolated platform. So the integer tiebreak is AEAD-encrypted
  # (AES-256-GCM) under a per-tenant, per-namespace key BEFORE it enters the payload;
  # the server decrypts it back to the real `seq` to run the keyset walk, but the
  # holder sees only opaque ciphertext + a random IV. The UUID tiebreak is a random
  # v4 `id` that reveals nothing about volume, so it stays in plaintext — encrypting
  # it would needlessly break in-flight article/changes cursors for zero benefit.
  defp serialize(_namespace, _tenant_id, %DateTime{} = inserted_at, id) when is_binary(id) do
    micros = DateTime.to_unix(inserted_at, :microsecond)
    {:ok, raw} = Ecto.UUID.dump(id)
    :erlang.term_to_binary({:k, micros, raw})
  end

  defp serialize(namespace, tenant_id, %DateTime{} = inserted_at, seq) when is_integer(seq) do
    micros = DateTime.to_unix(inserted_at, :microsecond)
    {iv, ct, tag} = encrypt_seq(namespace, tenant_id, seq)
    :erlang.term_to_binary({:kie, micros, iv, ct, tag})
  end

  defp deserialize(namespace, tenant_id, payload) do
    case safe_binary_to_term(payload) do
      {:k, micros, raw}
      when is_integer(micros) and is_binary(raw) and byte_size(raw) == 16 ->
        with {:ok, datetime} <- from_unix_micros(micros),
             {:ok, id} <- Ecto.UUID.load(raw) do
          {:ok, {datetime, id}}
        else
          _ -> {:error, :invalid}
        end

      {:kie, micros, iv, ct, tag}
      when is_integer(micros) and is_binary(iv) and is_binary(ct) and is_binary(tag) ->
        with {:ok, datetime} <- from_unix_micros(micros),
             {:ok, seq} <- decrypt_seq(namespace, tenant_id, iv, ct, tag) do
          {:ok, {datetime, seq}}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  # AEAD (AES-256-GCM) encrypt/decrypt of the integer `seq` tiebreak under a
  # per-tenant, per-namespace cipher key. A fresh random 12-byte IV per encode means
  # the ciphertext (and the whole cursor) is non-deterministic — the holder cannot
  # even tell whether two cursors carry the same `seq`. The `seq` is a signed 64-bit
  # (bigserial fits `int8`), so the plaintext is a fixed 8 bytes. The GCM tag adds
  # integrity of its own on top of the outer HMAC (defense in depth).
  @seq_aad "loopctl.keyset_cursor.seq.v1"

  defp encrypt_seq(namespace, tenant_id, seq) do
    key = cipher_key(namespace, tenant_id)
    iv = :crypto.strong_rand_bytes(12)

    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        <<seq::signed-integer-64>>,
        @seq_aad,
        true
      )

    {iv, ct, tag}
  end

  defp decrypt_seq(namespace, tenant_id, iv, ct, tag)
       when byte_size(iv) == 12 and byte_size(tag) == 16 do
    key = cipher_key(namespace, tenant_id)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, @seq_aad, tag, false) do
      <<seq::signed-integer-64>> -> {:ok, seq}
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  defp decrypt_seq(_namespace, _tenant_id, _iv, _ct, _tag), do: {:error, :invalid}

  # 32-byte AES-256 key, derived by hashing the per-tenant/per-namespace HMAC secret
  # material with a DISTINCT infix so the cipher key is independent of the HMAC key
  # over the same (namespace, tenant) pair.
  defp cipher_key(namespace, tenant_id) do
    :crypto.hash(:sha256, secret(namespace, tenant_id) <> ":seq-cipher")
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

  defp verify(namespace, tenant_id, payload, sig) do
    expected = :crypto.mac(:hmac, :sha256, secret(namespace, tenant_id), payload)

    if :crypto.hash_equals(expected, sig), do: :ok, else: {:error, :invalid}
  end

  # Per-tenant, per-namespace HMAC key: app secret_key_base + namespace + tenant_id.
  # Stable across nodes without storing a per-tenant secret. Mirrors
  # BulkOps.confirm_secret/1.
  #
  # FAIL CLOSED: `secret_key_base` is fetched (not defaulted). If it were ever absent,
  # signing with a guessable constant would silently defeat the entire
  # tenant-binding/forgery guarantee (a known key + a non-secret tenant_id = a
  # forgeable cursor); raising instead is the safe failure. `runtime.exs` already
  # requires SECRET_KEY_BASE in prod and the test/dev configs set it, so this raise is
  # unreachable in every real environment — it is a guard, not a path.
  #
  # The `:<namespace>:` infix namespaces this key away from BulkOps.confirm_secret/1
  # AND from other cursor namespaces, and binds it to the tenant. `tenant_id` is an
  # Ecto `binary_id` (a canonical UUID), which cannot contain the `:` delimiter, so no
  # two distinct tenants can derive the same key string — no cross-tenant collision.
  # Distinct namespaces likewise derive distinct keys — no cross-surface replay.
  defp secret(namespace, tenant_id) do
    base =
      :loopctl
      |> Application.fetch_env!(LoopctlWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    base <> ":" <> namespace <> ":" <> to_string(tenant_id)
  end
end
