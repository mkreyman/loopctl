defmodule Loopctl.LogValue do
  @moduledoc """
  What a client-supplied value may be written into a log line or Logger metadata as (issue
  #815).

  A value with the shape it claims is logged as itself; anything else is `:invalid`, never
  the value, so a request or a runner frame cannot put a multi-kilobyte string, a bignum or
  a nested term into the log stream. An absent value (`nil`) stays `nil`, which
  `Logger.metadata/1` treats as "unset". Every place a client-supplied id or epoch reaches a
  log goes through here, so the bound is one definition.
  """

  @max_bigint 9_223_372_036_854_775_807

  @doc "A claim epoch: a non-negative integer a Postgres `bigint` holds, else `:invalid`."
  @spec epoch(term()) :: non_neg_integer() | nil | :invalid
  def epoch(nil), do: nil
  def epoch(epoch) when is_integer(epoch) and epoch >= 0 and epoch <= @max_bigint, do: epoch
  def epoch(_value), do: :invalid

  @doc """
  A UUID in its 36-character hyphenated text form, normalized to lowercase, else `:invalid`.

  Only the text form: `Ecto.UUID.cast/1` alone also accepts any 16-byte binary as a RAW UUID
  and hex-encodes it, which would log `"aaaaaaaaaaaaaaaa"` as a fabricated id.
  """
  @spec uuid(term()) :: Ecto.UUID.t() | nil | :invalid
  def uuid(nil), do: nil

  def uuid(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> :invalid
    end
  end

  def uuid(_value), do: :invalid
end
