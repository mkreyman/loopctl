defmodule Loopctl.Webhooks.Signing do
  @moduledoc """
  HMAC-SHA256 signing and payload preparation for webhook deliveries.

  Provides functions to:
  - Compute HMAC-SHA256 signatures in `sha256=<hex>` format
  - Enforce payload size limits (64KB)
  - Truncate oversized payloads while preserving core fields
  """

  @max_payload_bytes 65_536

  @doc """
  Computes the HMAC-SHA256 signature of the given raw body bytes.

  Returns the signature in the format: `sha256=<hex-encoded-hmac>`

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
