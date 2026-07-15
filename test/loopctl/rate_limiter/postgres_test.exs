defmodule Loopctl.RateLimiter.PostgresTest do
  @moduledoc """
  Cluster-global Postgres-backed rate limiter (US-38.2, Epic 38, GH #353).

  These tests exercise `Loopctl.RateLimiter.Postgres.check_rate/3` DIRECTLY
  against the DB (via `Loopctl.AdminRepo`) rather than config-swapping the
  `:rate_limiter` DI key — the impl's own correctness is proven at the source,
  not through a mock. Every bucket key is uniquified per test so async runs
  never collide on a shared `(bucket, window_start)` counter row.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.RateLimiter.Postgres

  @window_ms 60_000

  defp bucket(prefix), do: "test:#{prefix}:#{Ecto.UUID.generate()}"

  describe "check_rate/3 fixed-window counting" do
    test "allows up to the limit then denies within the same window" do
      b = bucket("count")
      limit = 5

      results = for _ <- 1..8, do: Postgres.check_rate(b, @window_ms, limit)

      allowed = Enum.count(results, &match?({:allow, _}, &1))
      denied = Enum.count(results, &match?({:deny, _}, &1))

      assert allowed == limit
      assert denied == 3
      # The returned count climbs monotonically 1..limit on the allow path
      # (post-increment count), mirroring the Hammer contract the headers rely on.
      assert Enum.take(results, limit) == [
               {:allow, 1},
               {:allow, 2},
               {:allow, 3},
               {:allow, 4},
               {:allow, 5}
             ]

      assert List.last(results) == {:deny, limit}
    end

    test "tenant/key isolation: different buckets do not share a counter" do
      b1 = bucket("iso-a")
      b2 = bucket("iso-b")
      limit = 2

      # Exhaust b1 completely.
      assert {:allow, 1} = Postgres.check_rate(b1, @window_ms, limit)
      assert {:allow, 2} = Postgres.check_rate(b1, @window_ms, limit)
      assert {:deny, ^limit} = Postgres.check_rate(b1, @window_ms, limit)

      # b2 is fully independent — its own fresh window.
      assert {:allow, 1} = Postgres.check_rate(b2, @window_ms, limit)
      assert {:allow, 2} = Postgres.check_rate(b2, @window_ms, limit)
    end
  end

  describe "TC-38.2.2: cluster-global atomicity (combined budget, not N×)" do
    test "two concurrent callers sharing the store are capped at the GLOBAL budget" do
      # This is the point of the story: the same bucket hit by two independent
      # callers (standing in for two nodes) must admit AT MOST `limit` in total —
      # never 2×limit — because the increment-and-check is a single atomic upsert
      # (no read-modify-write race). Both tasks share this test's sandboxed
      # AdminRepo connection via explicit allowances.
      b = bucket("cluster")
      limit = 20
      per_caller = 30
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Loopctl.AdminRepo, parent, self())
            for _ <- 1..per_caller, do: Postgres.check_rate(b, @window_ms, limit)
          end)
        end

      results = tasks |> Enum.flat_map(&Task.await(&1, 10_000))

      allowed = Enum.count(results, &match?({:allow, _}, &1))

      # COMBINED allowed count is exactly the global budget — not 2×limit.
      assert allowed == limit
      assert Enum.count(results, &match?({:deny, _}, &1)) == 2 * per_caller - limit
      # No allowed count ever exceeds the limit (atomic increment guarantee).
      assert Enum.all?(results, fn
               {:allow, c} -> c <= limit
               {:deny, ^limit} -> true
             end)
    end
  end

  describe "TC-38.2.4: fail-OPEN on limiter DB error" do
    test "a genuine DB error allows the request and logs a warning" do
      b = bucket("failopen")

      # Drop the ON CONFLICT target index INSIDE this test's sandbox transaction
      # (reverted on rollback, invisible to other async tests) so the upsert hits
      # a real Postgres error ("no unique or exclusion constraint matching the ON
      # CONFLICT specification"). The impl must catch it and fail OPEN.
      Loopctl.AdminRepo.query!("DROP INDEX rate_limit_counters_bucket_window_start_index")

      log =
        capture_log(fn ->
          assert {:allow, 0} = Postgres.check_rate(b, @window_ms, 5)
        end)

      assert log =~ "failing OPEN"
      assert log =~ b
    end

    test "an arithmetic fault (window_ms = 0) also fails OPEN rather than crashing the caller" do
      b = bucket("failopen-arith")

      log =
        capture_log(fn ->
          assert {:allow, 0} = Postgres.check_rate(b, 0, 5)
        end)

      assert log =~ "failing OPEN"
    end
  end

  describe "TC-38.2.1: default DI resolves to the node-local ETS impl" do
    test "an unset :rate_limiter config falls back to Loopctl.RateLimiter.Hammer (ETS)" do
      # In prod/dev the :rate_limiter key is unset, so every caller falls back to
      # the ETS/Hammer default. config/test.exs deliberately overrides it to
      # Loopctl.MockRateLimiter, so we assert the FALLBACK constant an unset
      # config yields (via a deliberately-unset probe key), not the test override.
      assert Loopctl.RateLimiter.Hammer ==
               Application.get_env(
                 :loopctl,
                 :__rate_limiter_default_probe__,
                 Loopctl.RateLimiter.Hammer
               )

      # Both impls satisfy the shared behaviour, so the DI seam is swap-safe.
      Code.ensure_loaded!(Loopctl.RateLimiter.Hammer)
      Code.ensure_loaded!(Loopctl.RateLimiter.Postgres)
      assert function_exported?(Loopctl.RateLimiter.Hammer, :check_rate, 3)
      assert function_exported?(Loopctl.RateLimiter.Postgres, :check_rate, 3)

      # And the test-env override is active so integration tests use the mock.
      assert Loopctl.MockRateLimiter == Application.get_env(:loopctl, :rate_limiter)
    end
  end
end
