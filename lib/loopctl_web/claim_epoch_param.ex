defmodule LoopctlWeb.ClaimEpochParam do
  @moduledoc """
  The ONE reading of a `claim_epoch` request field: a non-negative JSON integer within int4,
  never a string. Each endpoint decides what status a malformed one earns.
  """

  @max 2_147_483_647

  @doc "The largest epoch accepted, the int4 bound of the column; published in the OpenAPI."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc "`{:ok, epoch}`, `:missing`, or `:malformed`."
  @spec fetch(map()) :: {:ok, non_neg_integer()} | :missing | :malformed
  # Bounded to int4: `claim_epoch` is an integer column, and a larger value fails to encode.
  def fetch(%{"claim_epoch" => epoch})
      when is_integer(epoch) and epoch >= 0 and epoch <= @max,
      do: {:ok, epoch}

  def fetch(%{"claim_epoch" => nil}), do: :missing
  def fetch(%{"claim_epoch" => _}), do: :malformed
  def fetch(_params), do: :missing
end
