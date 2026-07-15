defmodule Loopctl.RateLimiter.FailOpenLogTest do
  @moduledoc """
  US-38.2 — the throttled, PII-safe fail-open logger. Proves a sustained limiter
  outage can't flood the logs (one line per bucket-family per window) and that
  client IPs / UUIDs never reach the log message.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Loopctl.RateLimiter.FailOpenLog

  # A bucket whose LAST segment is dropped to form the family, so the retained
  # prefix is unique per test → no interference from other async fail-open logs.
  defp unique_bucket, do: "test_family_#{System.unique_integer([:positive])}:suffix"

  defp count(log, needle) do
    log |> String.split(needle) |> length() |> Kernel.-(1)
  end

  test "throttles repeated warnings for the same (source, family) to one per window" do
    bucket = unique_bucket()
    [family, _suffix] = String.split(bucket, ":")

    log =
      capture_log(fn ->
        for _ <- 1..25, do: FailOpenLog.warn(:postgres, bucket, "db down")
      end)

    assert count(log, "family=#{family}") == 1
  end

  test "different families each emit (throttle is per-family, not global)" do
    b1 = unique_bucket()
    b2 = unique_bucket()
    [f1, _] = String.split(b1, ":")
    [f2, _] = String.split(b2, ":")

    log =
      capture_log(fn ->
        FailOpenLog.warn(:postgres, b1, "x")
        FailOpenLog.warn(:postgres, b2, "x")
      end)

    assert count(log, "family=#{f1}") == 1
    assert count(log, "family=#{f2}") == 1
  end

  test "strips the identifying suffix (client IP / UUID) from the message" do
    ip = "203.0.113.#{System.unique_integer([:positive])}"
    # Craft a unique family so the assertion is isolated, with an IP suffix.
    family = "api_signup_#{System.unique_integer([:positive])}:ip"
    bucket = "#{family}:#{ip}"

    log = capture_log(fn -> FailOpenLog.warn(:security, bucket, "db down") end)

    assert log =~ "family=#{family}"
    refute log =~ ip
  end
end
