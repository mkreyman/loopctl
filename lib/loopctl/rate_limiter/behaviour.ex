defmodule Loopctl.RateLimiter.Behaviour do
  @moduledoc """
  Behaviour for rate limiting operations.

  Allows DI-based swapping of the rate limiter implementation
  for testing purposes.
  """

  @callback check_rate(String.t(), non_neg_integer(), non_neg_integer()) ::
              {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
end
