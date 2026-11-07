defmodule LoopctlRunner.Uuid do
  @moduledoc """
  The one uuid shape this runner checks, in the two readings its callers need.

  `valid?/1` is the contract's `format: uuid`, in either case: an id loopctl sends, or one this
  runner minted, checked before it names a file, a directory or a glob. `lowercase?/1` is the
  stricter reading, for a value that is only ever written lowercase and whose uppercase spelling
  would therefore be a different string naming the same thing: the operator's `runner_id`.
  """

  @doc "Whether `value` is a uuid, in either case."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value),
    do: value =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def valid?(_value), do: false

  @doc "Whether `value` is a uuid written in lowercase."
  @spec lowercase?(term()) :: boolean()
  def lowercase?(value) when is_binary(value),
    do: value =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def lowercase?(_value), do: false
end
