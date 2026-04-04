defmodule Loopctl.TokenUsage.Formatting do
  @moduledoc """
  Formatting helpers for token usage display.

  Provides human-readable formatting for token counts and costs.

  ## Examples

      iex> Loopctl.TokenUsage.Formatting.millicents_to_dollars(2500)
      "0.03"

      iex> Loopctl.TokenUsage.Formatting.format_tokens(1_500_000)
      "1.5M"
  """

  @doc """
  Converts millicents (1/1000 of a cent) to a dollar string rounded to 2 decimal places.

  Uses round-half-up rounding (standard financial rounding).

  ## Examples

      iex> millicents_to_dollars(0)
      "0.00"

      iex> millicents_to_dollars(2500)
      "0.03"

      iex> millicents_to_dollars(100_000)
      "1.00"

      iex> millicents_to_dollars(155)
      "0.00"
  """
  @spec millicents_to_dollars(integer() | Decimal.t() | nil) :: String.t()
  def millicents_to_dollars(nil), do: "0.00"

  def millicents_to_dollars(%Decimal{} = millicents) do
    millicents
    |> Decimal.div(100_000)
    |> Decimal.round(2, :half_up)
    |> Decimal.to_string(:normal)
    |> pad_dollars()
  end

  def millicents_to_dollars(millicents) when is_integer(millicents) do
    # millicents / 100_000 = dollars
    # Round to 2 decimal places using round-half-up
    millicents
    |> Decimal.new()
    |> Decimal.div(100_000)
    |> Decimal.round(2, :half_up)
    |> Decimal.to_string(:normal)
    |> pad_dollars()
  end

  @doc """
  Formats a token count for human-readable display.

  - Values under 1000 are shown as-is
  - Values >= 1000 and < 1_000_000 are shown as "XK" or "X.YK"
  - Values >= 1_000_000 are shown as "XM" or "X.YM"

  ## Examples

      iex> format_tokens(500)
      "500"

      iex> format_tokens(1000)
      "1K"

      iex> format_tokens(1500)
      "1.5K"

      iex> format_tokens(1_000_000)
      "1M"

      iex> format_tokens(2_500_000)
      "2.5M"
  """
  @spec format_tokens(integer() | nil) :: String.t()
  def format_tokens(nil), do: "0"

  def format_tokens(tokens) when is_integer(tokens) and tokens >= 1_000_000 do
    whole = div(tokens, 1_000_000)
    frac = div(rem(tokens, 1_000_000), 100_000)

    if frac == 0 do
      "#{whole}M"
    else
      "#{whole}.#{frac}M"
    end
  end

  def format_tokens(tokens) when is_integer(tokens) and tokens >= 1000 do
    whole = div(tokens, 1000)
    frac = div(rem(tokens, 1000), 100)

    if frac == 0 do
      "#{whole}K"
    else
      "#{whole}.#{frac}K"
    end
  end

  def format_tokens(tokens) when is_integer(tokens), do: to_string(tokens)

  # Ensure dollar strings always have 2 decimal places
  defp pad_dollars(str) do
    case String.split(str, ".") do
      [whole] -> whole <> ".00"
      [whole, dec] when byte_size(dec) == 1 -> whole <> "." <> dec <> "0"
      _ -> str
    end
  end
end
