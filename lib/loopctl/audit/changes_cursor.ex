defmodule Loopctl.Audit.ChangesCursor do
  @moduledoc """
  Integrity-protected, tenant-bound keyset cursor for the change feed (US-27.9b).

  The change feed (`GET /api/v1/changes`) paginates audit-log entries in ascending
  time order. The ORIGINAL token was TIMESTAMP-ONLY (`next_since` = the last row's
  `inserted_at`), which is NOT a sound keyset: audit `inserted_at` is
  `utc_datetime_usec` and bulk operations (an `Ecto.Multi` writing several entries,
  or `insert_all`) commit MULTIPLE rows at the SAME microsecond. A page boundary
  that lands mid-tie then either SKIPS the tied rows after the boundary (the next
  `inserted_at > ^since` excludes everything at that exact timestamp) — a silent
  gap — or, with `>=`, RE-EMITS them — a duplicate. This is the same tie-induced
  drift the article-list keyset (US-27.9a) fixed with an `id` tie-break.

  This cursor encodes the stable unique tuple `(inserted_at, id)` so the feed seeks

      WHERE tenant_id = ^tenant_id
        AND (inserted_at, id) > (^c_inserted, ^c_id)
      ORDER BY inserted_at ASC, id ASC

  which steps PAST a specific row regardless of how many share its timestamp — no
  skip, no duplicate.

  ## Trust model (AC-27.9b.4)

  Identical to `Loopctl.Knowledge.ArticleCursor` (the article-list keyset), with a
  DISTINCT per-tenant key namespace (`:changes_cursor:`) so a change-feed cursor and
  an article cursor are not interchangeable even within one tenant:

  - It encodes ONLY an intra-tenant ordering position `(inserted_at, id)`. The
    caller's tenant always comes from the authenticated principal — never the cursor.
  - It is HMAC-SHA256 signed with a PER-TENANT key derived from the app
    `secret_key_base` + the tenant_id. `decode/2` verifies with the CALLER's tenant
    key, so a cursor minted for tenant B fails verification for tenant A.
  - `decode/2` is DEFENSIVE: garbage, a bit-flipped signature, a tampered payload,
    or a wrong-tenant cursor all return `{:error, :invalid}` — never a raise.

  The signature is compared in constant time (`:crypto.hash_equals/2`).
  """

  @hmac_bytes 32

  @typedoc "The keyset position: the `(inserted_at, id)` of an audit row in (inserted_at ASC, id ASC) order."
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

  ANY problem — malformed Base64, wrong length, signature mismatch (tampered OR a
  wrong-tenant cursor), or an undeserializable payload — returns `{:error, :invalid}`.
  Never raises; never leaks why it failed.
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

  # --- internals (mirror Loopctl.Knowledge.ArticleCursor verbatim) ---

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

  # Per-tenant HMAC key: app secret_key_base + tenant_id. The `:changes_cursor:`
  # infix namespaces this key away from the article cursor and binds it to the
  # tenant. FAIL CLOSED: `secret_key_base` is fetched (not defaulted).
  defp secret(tenant_id) do
    base =
      :loopctl
      |> Application.fetch_env!(LoopctlWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    base <> ":changes_cursor:" <> to_string(tenant_id)
  end
end
