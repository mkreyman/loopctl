defmodule LoopctlWeb.RunnerChannel.ReplyBucketTest do
  @moduledoc """
  The `dispatch_reply` bucket's refill arithmetic, at fixed times: the clock is an argument,
  so nothing here depends on how long a test takes to run.
  """

  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias LoopctlWeb.RunnerChannel.ReplyBucket

  @burst RunnerContract.dispatch_reply_burst()
  @capacity @burst["capacity"]
  @refill @burst["refill_interval_ms"]

  defp take(bucket, now), do: ReplyBucket.take(bucket, now, @capacity, @refill)

  # Spends `n` tokens at the same instant, returning the last bucket or the first refusal.
  defp take_n(bucket, n, now) do
    Enum.reduce_while(1..n, {:ok, bucket}, fn _, {:ok, b} ->
      case take(b, now) do
        {:ok, b} -> {:cont, {:ok, b}}
        refused -> {:halt, refused}
      end
    end)
  end

  test "a full bucket admits exactly capacity replies at one instant, then refuses" do
    assert {:ok, drained} = take_n(:full, @capacity, 1_000)
    assert drained == {0, 1_000}
    assert {:error, :rate_limited} = take(drained, 1_000)
  end

  test "a token is earned at exactly one refill interval, not a millisecond before" do
    {:ok, drained} = take_n(:full, @capacity, 1_000)

    assert {:error, :rate_limited} = take(drained, 1_000 + @refill - 1)
    assert {:ok, {0, refilled_at}} = take(drained, 1_000 + @refill)
    assert refilled_at == 1_000 + @refill
  end

  test "a partial interval is kept, so tokens accrue at the refill rate and never past capacity" do
    {:ok, drained} = take_n(:full, @capacity, 0)

    # Two and a half intervals earn two tokens, and the half interval carries over.
    assert {:ok, {1, refilled_at}} = take(drained, div(5 * @refill, 2))
    assert refilled_at == 2 * @refill

    # A long idle period refills to capacity and no further.
    assert {:ok, {left, _}} = take(drained, 1_000 * @refill)
    assert left == @capacity - 1
  end

  test "a clock that reads earlier than the last refill earns nothing" do
    {:ok, drained} = take_n(:full, @capacity, 10_000)
    assert {:error, :rate_limited} = take(drained, 0)
  end

  test "the published burst is a real burst" do
    assert @capacity > 1
    assert @refill > 0
  end
end
