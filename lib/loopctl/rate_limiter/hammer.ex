defmodule Loopctl.RateLimiter.Hammer do
  @moduledoc """
  Production rate limiter implementation using the Hammer library.
  """

  @behaviour Loopctl.RateLimiter.Behaviour

  @impl true
  def check_rate(bucket, window_ms, limit) do
    Hammer.check_rate(bucket, window_ms, limit)
  end
end
