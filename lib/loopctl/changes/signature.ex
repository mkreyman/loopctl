defmodule Loopctl.Changes.Signature do
  @moduledoc """
  The HMAC both directions of the chg change protocol are signed with (US-47.3, Epic 47
  PRD §5; wire contract confirmed on mkreyman/chg#33).

  - **Delivery** (chg-server → loopctl): `X-Chg-Timestamp: <unix seconds>` and
    `X-Chg-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<raw body>">`, keyed by the
    intake source's `change_events_secret`.
  - **Gap pull** (loopctl → chg-server): the same two headers, over
    `"<timestamp>.GET.<path>?<query>"` exactly as sent.

  Both are judged inside a 300-second window either side of now. chg signs at send time,
  so a redelivery carries a fresh timestamp and stays inside it.

  `verify/5` does the same HMAC work whether the signature header is well-formed or not, and
  whether the timestamp is in the window or not, so a caller cannot tell those apart by
  timing; the comparison is `Plug.Crypto.secure_compare/2`.
  """

  @window_seconds 300
  @header_format ~r/\Asha256=([0-9a-fA-F]{64})\z/
  @timestamp_format ~r/\A[0-9]{1,12}\z/
  @placeholder String.duplicate("0", 64)

  @doc "The replay window, in seconds, either side of now."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc "The lowercase hex HMAC-SHA256 of `signed` under `secret`."
  @spec sign(binary(), binary()) :: String.t()
  def sign(secret, signed) when is_binary(secret) and is_binary(signed) do
    :hmac |> :crypto.mac(:sha256, secret, signed) |> Base.encode16(case: :lower)
  end

  @doc "The string a delivery's signature covers: `\"<timestamp>.<raw body>\"`."
  @spec delivery_string(String.t(), binary()) :: binary()
  def delivery_string(timestamp, raw_body), do: timestamp <> "." <> raw_body

  @doc """
  The string a gap pull's signature covers: `\"<timestamp>.GET.<path>?<query>\"`, with the
  path and query exactly as the request sends them.
  """
  @spec pull_string(String.t(), String.t(), String.t()) :: String.t()
  def pull_string(timestamp, path, query), do: "#{timestamp}.GET.#{path}?#{query}"

  @doc "The `X-Chg-Signature` value for `signed` under `secret`."
  @spec header(binary(), binary()) :: String.t()
  def header(secret, signed), do: "sha256=" <> sign(secret, signed)

  @doc """
  Judges a delivery: `:ok`, `{:error, :bad_signature}` or `{:error, :stale_timestamp}`.

  `now` is unix seconds, an input so the window is testable without a clock.
  """
  @spec verify(binary(), String.t() | nil, binary(), String.t() | nil, integer()) ::
          :ok | {:error, :bad_signature | :stale_timestamp}
  def verify(secret, timestamp, raw_body, signature, now)
      when is_binary(secret) and is_binary(raw_body) and is_integer(now) do
    {ts_text, ts} = parse_timestamp(timestamp)
    expected = sign(secret, delivery_string(ts_text, raw_body))
    {provided, well_formed?} = provided(signature)
    matches? = Plug.Crypto.secure_compare(expected, provided) and well_formed?

    cond do
      not matches? -> {:error, :bad_signature}
      not in_window?(ts, now) -> {:error, :stale_timestamp}
      true -> :ok
    end
  end

  @doc "Whether `timestamp` (unix seconds) is inside the window around `now`."
  @spec in_window?(integer() | nil, integer()) :: boolean()
  def in_window?(ts, now) when is_integer(ts) and is_integer(now),
    do: abs(now - ts) <= @window_seconds

  def in_window?(_ts, _now), do: false

  # A malformed or absent header is compared as a placeholder, so the comparison still runs.
  defp provided(signature) when is_binary(signature) do
    case Regex.run(@header_format, signature, capture: :all_but_first) do
      [hex] -> {String.downcase(hex), true}
      _ -> {@placeholder, false}
    end
  end

  defp provided(_signature), do: {@placeholder, false}

  # A malformed or absent timestamp still feeds the HMAC (as the empty string), so the work
  # done does not depend on it; it then fails the window.
  defp parse_timestamp(value) when is_binary(value) do
    if Regex.match?(@timestamp_format, value),
      do: {value, String.to_integer(value)},
      else: {"", nil}
  end

  defp parse_timestamp(_value), do: {"", nil}
end
