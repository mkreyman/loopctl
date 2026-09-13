defmodule LoopctlWeb.RunnerChannel.MinIntervalTest do
  @moduledoc """
  The channel's per-event rate floor, at fixed times: the clock is an argument, so nothing
  here depends on how long a test takes to run.
  """

  use ExUnit.Case, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias LoopctlWeb.RunnerChannel.MinInterval

  @status_floor RunnerContract.min_interval_ms("status")

  test "the first message is always admitted, even on a negative monotonic clock" do
    assert :ok = MinInterval.check(:never, -576_460_752_303, @status_floor)
  end

  test "a message a millisecond inside the floor is refused, and one exactly at it admitted" do
    last = 10_000

    assert {:error, :rate_limited} = MinInterval.check(last, last, @status_floor)

    assert {:error, :rate_limited} =
             MinInterval.check(last, last + @status_floor - 1, @status_floor)

    assert :ok = MinInterval.check(last, last + @status_floor, @status_floor)
    assert :ok = MinInterval.check(last, last + 10 * @status_floor, @status_floor)
  end

  test "negative monotonic times compare the same way" do
    last = -5_000

    assert {:error, :rate_limited} =
             MinInterval.check(last, last + @status_floor - 1, @status_floor)

    assert :ok = MinInterval.check(last, last + @status_floor, @status_floor)
  end

  test "a clock that reads earlier than the last admitted message is refused" do
    assert {:error, :rate_limited} = MinInterval.check(10_000, 9_000, @status_floor)
  end
end
