defmodule Loopctl.Webhooks.Signing do
  @moduledoc """
  HMAC-SHA256 signing and payload preparation for webhook deliveries.

  Provides functions to:
  - Compute timestamped `t=<unix>,v1=<hex>` signatures (the CURRENT scheme)
  - Compute legacy `sha256=<hex>` signatures (DEPRECATED, still emitted)
  - Verify a received signature against a tolerance window
  - Enforce payload size limits (64KB)
  - Truncate oversized payloads while preserving core fields

  ## What the signature binds (issue #623)

  The legacy scheme signed the BODY ALONE, so the signature was a property of the
  payload rather than of a delivery: any party that observed one valid
  `(body, signature)` pair held a token that stayed valid forever, and a receiver
  had no signed fact to date it by. The `x-webhook-timestamp` header existed but
  sat OUTSIDE the MAC, so it was freely rewritable.

  The v1 scheme binds the timestamp INTO the signed string:

      signing_string = "<unix_timestamp>.<raw_body>"
      signature      = "t=<unix_timestamp>,v1=" <> hex(hmac_sha256(secret, signing_string))

  A receiver therefore has two independent facts it can check itself: the
  signature proves the timestamp was chosen by the sender, and the timestamp
  bounds how long that signature is worth honouring.

  ## Receiver contract

  1. Read `x-webhook-signature`, parse `t=` and `v1=`.
  2. Recompute `hmac_sha256(secret, "<t>.<raw_body>")` over the RAW body bytes —
     not a re-encoded parse — and compare in constant time.
  3. Reject when `|now - t|` exceeds the tolerance. The RECOMMENDED window is
     five minutes — `tolerance_seconds/0` is the one definition — which absorbs
     ordinary clock skew and retry latency without leaving a wide acceptance
     window.
  4. Keep a short-lived cache of `x-webhook-id` (the delivery id, unique per
     delivery event) covering at least the tolerance window, and drop a delivery
     whose id was already processed. Steps 3 and 4 are complementary: the window
     bounds the lifetime of a captured signature, the id cache prevents reuse
     WITHIN it. loopctl retries a failed delivery with the SAME `x-webhook-id`,
     so the cache must key acceptance on "already processed successfully".

  ## Deprecation window

  Both headers are sent on every delivery:

    * `x-webhook-signature` — the v1 scheme above. New receivers verify this one.
    * `x-signature-256` — the legacy `sha256=<hmac(body)>` value. Emitted so
      existing receivers keep working while they migrate; it carries none of the
      properties above and will be removed.
  """

  @max_payload_bytes 65_536

  # The RECOMMENDED receiver tolerance. loopctl does not enforce it (it is the
  # sender), but `verify/4` applies it so the contract has one definition and a
  # receiver implementation has something to mirror.
  @tolerance_seconds 300

  @typedoc "A parse failure or a verification failure, distinguishable by the caller."
  @type verify_error ::
          :malformed_signature
          | :unsupported_scheme
          | :timestamp_out_of_tolerance
          | :signature_mismatch

  @doc """
  The RECOMMENDED receiver tolerance window, in seconds.

  A receiver should reject a delivery whose `t=` differs from its own clock by
  more than this. Referenced by the docs and by `verify/4` so the recommendation
  and the reference implementation cannot drift.
  """
  @spec tolerance_seconds() :: pos_integer()
  def tolerance_seconds, do: @tolerance_seconds

  @doc """
  Signs `body` for `timestamp` (unix seconds), returning `t=<ts>,v1=<hex>`.

  The MAC covers `"<timestamp>.<body>"`, so a captured signature cannot be
  re-presented under a different timestamp.

  ## Examples

      Signing.sign("{}", "secret", 1_700_000_000)
      #=> "t=1700000000,v1=<64 hex chars>"
  """
  @spec sign(binary(), binary(), integer()) :: String.t()
  def sign(body, secret, timestamp)
      when is_binary(body) and is_binary(secret) and is_integer(timestamp) do
    hmac =
      :crypto.mac(:hmac, :sha256, secret, signing_string(body, timestamp))
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{hmac}"
  end

  @doc """
  The exact bytes a v1 signature is computed over: `"<timestamp>.<body>"`.

  Public so a receiver implementation (and the tests) reproduce the sender's
  construction rather than restating it.
  """
  @spec signing_string(binary(), integer()) :: binary()
  def signing_string(body, timestamp) when is_binary(body) and is_integer(timestamp) do
    "#{timestamp}." <> body
  end

  @doc """
  Verifies a `t=<ts>,v1=<hex>` signature against `body` and `secret`.

  Returns `:ok`, or an error naming WHICH property failed — a stale timestamp is
  reported as `:timestamp_out_of_tolerance` and is never conflated with
  `:signature_mismatch`, so a receiver (and this repo's tests) can tell a replay
  of a genuinely-signed payload from a forgery.

  ## Options

    * `:now` — unix seconds to compare against (default `System.system_time(:second)`).
    * `:tolerance` — seconds of accepted skew (default `tolerance_seconds/0`).
  """
  @spec verify(String.t(), binary(), binary(), keyword()) :: :ok | {:error, verify_error()}
  def verify(signature, body, secret, opts \\ [])

  def verify(signature, body, secret, opts)
      when is_binary(signature) and is_binary(body) and is_binary(secret) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    tolerance = Keyword.get(opts, :tolerance, @tolerance_seconds)

    with {:ok, timestamp, mac} <- parse(signature),
         :ok <- check_tolerance(timestamp, now, tolerance) do
      expected = :crypto.mac(:hmac, :sha256, secret, signing_string(body, timestamp))

      # Constant-time: a byte-by-byte compare leaks the shared prefix length and
      # turns forgery into a per-byte search.
      if Plug.Crypto.secure_compare(expected, decode_mac(mac)) do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  def verify(_signature, _body, _secret, _opts), do: {:error, :malformed_signature}

  @doc """
  Parses a `t=<ts>,v1=<hex>` signature into `{:ok, timestamp, hex_mac}`.

  A value that is not in this form is `:malformed_signature`; a well-formed value
  naming a scheme other than `v1` is `:unsupported_scheme` — the two are distinct
  so a receiver can log "you sent an old header" separately from "this is garbage".
  """
  @spec parse(String.t()) :: {:ok, integer(), String.t()} | {:error, verify_error()}
  def parse(signature) when is_binary(signature) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    case parts do
      [["t", ts], [scheme, mac]] ->
        parse_parts(ts, scheme, mac)

      _ ->
        {:error, :malformed_signature}
    end
  end

  def parse(_signature), do: {:error, :malformed_signature}

  defp parse_parts(ts, scheme, mac) do
    case Integer.parse(ts) do
      {timestamp, ""} when scheme == "v1" -> {:ok, timestamp, mac}
      {_timestamp, ""} -> {:error, :unsupported_scheme}
      _ -> {:error, :malformed_signature}
    end
  end

  defp check_tolerance(timestamp, now, tolerance) do
    if abs(now - timestamp) <= tolerance do
      :ok
    else
      {:error, :timestamp_out_of_tolerance}
    end
  end

  # An undecodable hex MAC must not crash verification, and must not compare
  # equal to anything either.
  defp decode_mac(mac) do
    case Base.decode16(mac, case: :mixed) do
      {:ok, raw} -> raw
      :error -> <<>>
    end
  end

  @doc """
  Computes the LEGACY HMAC-SHA256 signature of the given raw body bytes.

  Returns the signature in the format: `sha256=<hex-encoded-hmac>`

  DEPRECATED — it signs the body alone, so a captured `(body, signature)` pair
  stays valid indefinitely and a receiver has no signed fact to date it by. It is
  still emitted (as `x-signature-256`) for the deprecation window so existing
  receivers keep working; verify `x-webhook-signature` instead (see `sign/3`).

  ## Parameters

  - `body` -- the raw JSON bytes to sign
  - `secret` -- the signing secret (decrypted)

  ## Examples

      iex> Signing.sign_payload("{}", "secret")
      "sha256=5d5d139563c95b5967b9bd9a8c9b233a9dedb45072794cd232dc1b74832607d0"
  """
  @spec sign_payload(binary(), binary()) :: String.t()
  def sign_payload(body, secret) when is_binary(body) and is_binary(secret) do
    hmac =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    "sha256=#{hmac}"
  end

  @doc """
  Prepares a delivery payload, truncating if it exceeds the 64KB limit.

  When the JSON-encoded payload exceeds 64KB, large data fields
  (`old_state`, `new_state`, `findings`) are replaced with truncation
  markers while core event fields are preserved.

  ## Parameters

  - `payload` -- the event payload map

  ## Returns

  The JSON-encoded binary string (always under 64KB).
  """
  @spec prepare_payload(map()) :: binary()
  def prepare_payload(payload) do
    json = Jason.encode!(payload)

    if byte_size(json) > @max_payload_bytes do
      truncated_payload =
        payload
        |> maybe_truncate_field("data")
        |> Map.put("truncated", true)

      Jason.encode!(truncated_payload)
    else
      json
    end
  end

  defp maybe_truncate_field(payload, "data") do
    case Map.get(payload, "data") do
      nil ->
        payload

      data when is_map(data) ->
        truncated_data =
          data
          |> Map.delete("old_state")
          |> Map.delete("new_state")
          |> Map.delete("findings")
          |> Map.put("_truncated_fields", ["old_state", "new_state", "findings"])

        Map.put(payload, "data", truncated_data)

      _ ->
        payload
    end
  end
end
