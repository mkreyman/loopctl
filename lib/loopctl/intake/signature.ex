defmodule Loopctl.Intake.Signature do
  @moduledoc """
  GitHub webhook signature verification (issue #803).

  GitHub signs every delivery with `X-Hub-Signature-256: sha256=<hex>`, the HMAC-SHA256
  of the RAW request body under the webhook's secret. Verification must run over the
  exact bytes received — never a re-encoding of parsed JSON, whose key order and
  whitespace differ — and must compare in constant time.

  `valid?/3` does the same work whether the header is well-formed, malformed or absent,
  so a caller cannot tell those apart by timing either.
  """

  @header_format ~r/\Asha256=([0-9a-fA-F]{64})\z/
  @placeholder String.duplicate("0", 64)

  @doc "Whether `header` is GitHub's signature of `raw_body` under `secret`."
  @spec valid?(binary(), binary(), String.t() | nil) :: boolean()
  def valid?(secret, raw_body, header) when is_binary(secret) and is_binary(raw_body) do
    expected = sign(secret, raw_body)

    {provided, well_formed?} =
      case is_binary(header) && Regex.run(@header_format, header, capture: :all_but_first) do
        [hex] -> {String.downcase(hex), true}
        _ -> {@placeholder, false}
      end

    Plug.Crypto.secure_compare(expected, provided) and well_formed?
  end

  @doc "The lowercase hex HMAC-SHA256 of `raw_body` under `secret`."
  @spec sign(binary(), binary()) :: String.t()
  def sign(secret, raw_body) when is_binary(secret) and is_binary(raw_body) do
    :hmac |> :crypto.mac(:sha256, secret, raw_body) |> Base.encode16(case: :lower)
  end

  @doc "The `X-Hub-Signature-256` header value GitHub would send for `raw_body`."
  @spec header(binary(), binary()) :: String.t()
  def header(secret, raw_body), do: "sha256=" <> sign(secret, raw_body)
end
