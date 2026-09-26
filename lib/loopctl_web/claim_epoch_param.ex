defmodule LoopctlWeb.ClaimEpochParam do
  @moduledoc """
  The ONE reading of a `claim_epoch` request field: a non-negative JSON integer, never a
  string. Each endpoint decides what status a malformed one earns.
  """

  @doc "`{:ok, epoch}`, `:missing`, or `:malformed`."
  @spec fetch(map()) :: {:ok, non_neg_integer()} | :missing | :malformed
  def fetch(%{"claim_epoch" => epoch}) when is_integer(epoch) and epoch >= 0, do: {:ok, epoch}
  def fetch(%{"claim_epoch" => nil}), do: :missing
  def fetch(%{"claim_epoch" => _}), do: :malformed
  def fetch(_params), do: :missing
end
