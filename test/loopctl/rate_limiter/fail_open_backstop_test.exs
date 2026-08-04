defmodule Loopctl.RateLimiter.FailOpenBackstopTest do
  use ExUnit.Case, async: true

  alias Loopctl.RateLimiter.FailOpenBackstop

  @window_ms 3_600_000

  # Each test owns its bucket, so the shared node-local table cannot couple them.
  setup context do
    bucket = "backstop_test:#{inspect(context.test)}"
    on_exit(fn -> FailOpenBackstop.reset(bucket) end)
    {:ok, bucket: bucket}
  end

  describe "charge/3" do
    test "admits up to the limit, then refuses", %{bucket: bucket} do
      for _ <- 1..3 do
        assert FailOpenBackstop.charge(bucket, @window_ms, 3) == :admitted
      end

      assert FailOpenBackstop.charge(bucket, @window_ms, 3) == :exhausted
    end

    test "stays refused for the rest of the window", %{bucket: bucket} do
      # The bound this exists for is SUSTAINED, not per-request: a flood that takes out the
      # primary meter keeps calling, and a backstop that refilled per request would be no
      # bound at all.
      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :admitted

      for _ <- 1..25 do
        assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :exhausted
      end
    end

    test "buckets are independent", %{bucket: bucket} do
      other = bucket <> ":other"
      on_exit(fn -> FailOpenBackstop.reset(other) end)

      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :admitted
      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :exhausted

      # One tenant (or lane) spending its allowance must not close the valve on another.
      assert FailOpenBackstop.charge(other, @window_ms, 1) == :admitted
    end

    test "a limit of 1 admits exactly once — the floor case", %{bucket: bucket} do
      # `fail_open_jobs_per_window/1` floors at 1, so this is the live configuration for any
      # OBAN_INGEST_BACKLOG_MAX below nodes x lanes. Off-by-one here would either refuse
      # everything (valve fail-closed) or never refuse (no bound).
      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :admitted
      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :exhausted
    end

    test "a shorter window is counted separately from a longer one", %{bucket: bucket} do
      # Window width is part of the key's index, so two callers using different widths cannot
      # silently share a counter.
      assert FailOpenBackstop.charge(bucket, 1_000, 1) == :admitted
      assert FailOpenBackstop.charge(bucket, @window_ms, 1) == :admitted
    end
  end

  describe "availability posture" do
    test "an unavailable table admits rather than crashing the caller" do
      # This sits on a FAIL-OPEN path: a caller reaching it before the app tree is up must not
      # take a crash from the thing that exists to keep it available. The real table is
      # supervised, so the branch is only reachable through the explicit-table arity.
      absent = :rate_limiter_fail_open_backstop_absent
      assert :ets.info(absent) == :undefined

      # Repeatedly, and past any plausible limit — a fallback that admitted once and then
      # raised would be worse than one that never worked.
      for _ <- 1..5 do
        assert FailOpenBackstop.charge("no-table", @window_ms, 1, absent) == :admitted
      end
    end

    test "the supervised table IS present, so the tests above are not all hitting the fallback" do
      # Vacuity guard: every assertion in this file would also pass against a missing table,
      # since the fallback admits. Pin that the real table exists and actually counts.
      assert :ets.info(:rate_limiter_fail_open_backstop) != :undefined
    end
  end
end
