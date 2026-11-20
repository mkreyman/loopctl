defmodule LoopctlRunner.ByteRule do
  @moduledoc """
  The contract's JSON byte rule (runner contract 1.1, `x-connection.limits.json_byte_rule`),
  which bounds a trace event and a trace batch independently of any encoder.

  The runner must count exactly as loopctl does (`ByteRule` in loopctl's `runner_contract.ex`):
  a batch it believes fits and the server refuses is resent forever. The constants are read
  from the vendored contract, never re-typed, and the algorithm follows the server's:

    * a string, object keys included: `per_string_char` per UTF-16 code unit (so a character
      outside the Basic Multilingual Plane counts twice) plus `per_string`;
    * a number, `true`, `false` or `null`: `per_scalar`;
    * an array or object: `per_container`, plus `per_member` for every element or member.
  """

  alias LoopctlRunner.Contract

  @rule get_in(Contract.connection(), ["limits", "json_byte_rule"])
  @per_char Map.fetch!(@rule, "per_string_char")
  @per_string Map.fetch!(@rule, "per_string")
  @per_scalar Map.fetch!(@rule, "per_scalar")
  @per_container Map.fetch!(@rule, "per_container")
  @per_member Map.fetch!(@rule, "per_member")

  @doc "The size of a decoded JSON term (string keys) under the byte rule."
  @spec bytes(term()) :: non_neg_integer()
  def bytes(term) when is_binary(term), do: @per_char * utf16_units(term, 0) + @per_string
  def bytes(term) when is_number(term) or term in [true, false, nil], do: @per_scalar

  def bytes(term) when is_list(term),
    do: @per_container + Enum.reduce(term, 0, &(&2 + @per_member + bytes(&1)))

  def bytes(term) when is_map(term) do
    @per_container +
      Enum.reduce(term, 0, fn {key, value}, acc ->
        acc + @per_member + bytes(to_string(key)) + bytes(value)
      end)
  end

  defp utf16_units(<<>>, n), do: n
  defp utf16_units(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: utf16_units(rest, n + 2)
  defp utf16_units(<<_c::utf8, rest::binary>>, n), do: utf16_units(rest, n + 1)
  # Not valid UTF-8: one unit per byte, as the server counts it. A decoded trace never has one.
  defp utf16_units(<<_byte, rest::binary>>, n), do: utf16_units(rest, n + 1)
end
