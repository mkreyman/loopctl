defmodule LoopctlWeb.RunnerChannel.ReplyBucket do
  @moduledoc """
  The `dispatch_reply` rate limit of `LoopctlWeb.RunnerChannel`: a token bucket of
  `capacity` replies, one more earned every `refill_ms`.

  Pure, and the clock is an argument, so the refill arithmetic is tested at fixed times
  rather than against the wall clock. The channel keeps the bucket in its assigns and passes
  `System.monotonic_time(:millisecond)`.

  A bucket is `:full` (a fresh channel) or `{tokens, refilled_at}`, where `refilled_at` is the
  time the last whole token was earned, so a partial interval is never lost.
  """

  @type t :: :full | {non_neg_integer(), integer()}

  @doc """
  Spends one token at `now`. Returns the bucket to keep, or `{:error, :rate_limited}` when
  none has been earned since the last one was spent.
  """
  @spec take(t(), integer(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, :rate_limited}
  def take(:full, now, capacity, _refill_ms), do: {:ok, {capacity - 1, now}}

  def take({tokens, refilled_at}, now, capacity, refill_ms) do
    earned = max(div(now - refilled_at, refill_ms), 0)

    {tokens, refilled_at} =
      if tokens + earned >= capacity,
        do: {capacity, now},
        else: {tokens + earned, refilled_at + earned * refill_ms}

    if tokens >= 1, do: {:ok, {tokens - 1, refilled_at}}, else: {:error, :rate_limited}
  end
end
