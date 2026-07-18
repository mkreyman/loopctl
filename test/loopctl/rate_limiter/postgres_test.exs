defmodule Loopctl.RateLimiter.PostgresTest do
  @moduledoc """
  Cluster-global Postgres-backed rate limiter (US-38.2, Epic 38, GH #353).

  These tests exercise `Loopctl.RateLimiter.Postgres.check_rate/3` DIRECTLY
  against the DB (via `Loopctl.AdminRepo`) rather than config-swapping the
  `:rate_limiter` DI key — the impl's own correctness is proven at the source,
  not through a mock. Every bucket key is uniquified per test so async runs
  never collide on a shared `(bucket, window_start)` counter row.

  The genuine cross-CONNECTION atomicity property (two independent DB
  connections racing the same counter row — the one thing this shared store
  exists to guarantee) is proven in `Loopctl.RateLimiter.PostgresConcurrencyTest`,
  which must run `async: false` against COMMITTED rows: a single sandbox
  connection serializes all statements and so cannot distinguish an atomic upsert
  from a racy read-modify-write.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Loopctl.RateLimiter.Postgres

  @window_ms 60_000

  defp bucket(prefix), do: "test:#{prefix}:#{Ecto.UUID.generate()}"

  # Pin the DI clock to a fixed instant well inside a single unix-minute window so
  # a multi-call `check_rate` SEQUENCE cannot straddle a real 60s window boundary
  # mid-test. Without this the default `MockClock` stub (DataCase) returns real
  # `DateTime.utc_now/0`; under full-suite load the several sequential AdminRepo
  # round-trips can cross the boundary, roll the counter to a fresh window_start,
  # and reset the count mid-sequence — the source of the intermittent
  # off-by-a-count / unexpected-allow failures. The instant is mid-window (t=30s)
  # so it is nowhere near either edge.
  defp pin_clock(instant \\ ~U[2026-07-15 10:00:30Z]) do
    stub(Loopctl.MockClock, :utc_now, fn -> instant end)
    :ok
  end

  describe "check_rate/3 fixed-window counting" do
    test "allows up to the limit then denies within the same window" do
      pin_clock()
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
      pin_clock()
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

  describe "fixed-window rollover (Hammer-equivalent reset at the boundary)" do
    test "the counter resets to zero when the window rolls over" do
      # AC-38.2.4: window semantics must match the Hammer fixed-window contract
      # "closely enough that a limit configured today means the same thing" — i.e.
      # the counter RESETS at the window boundary. The impl derives window_start
      # from the DI-injected clock, so we PIN the wall clock to one window, exhaust
      # the limit, then ADVANCE it into the next 60s window and assert the count
      # starts over from 1 (a fresh window opens) — the property that cannot be
      # asserted from inside a single real-time window.
      b = bucket("rollover")
      limit = 3

      # An Agent holds the "current" instant so a SINGLE stub deterministically
      # advances the clock across the boundary.
      w1 = ~U[2026-07-15 10:00:30Z]
      # +60s → the next unix-minute-aligned 60_000ms window.
      w2 = ~U[2026-07-15 10:01:30Z]
      {:ok, now} = Agent.start_link(fn -> w1 end)
      stub(Loopctl.MockClock, :utc_now, fn -> Agent.get(now, & &1) end)

      # Window 1: allow up to the limit, then deny.
      assert {:allow, 1} = Postgres.check_rate(b, @window_ms, limit)
      assert {:allow, 2} = Postgres.check_rate(b, @window_ms, limit)
      assert {:allow, 3} = Postgres.check_rate(b, @window_ms, limit)
      assert {:deny, ^limit} = Postgres.check_rate(b, @window_ms, limit)

      # Advance into window 2 → a fresh counter row; the budget resets to full.
      Agent.update(now, fn _ -> w2 end)
      assert {:allow, 1} = Postgres.check_rate(b, @window_ms, limit)
      assert {:allow, 2} = Postgres.check_rate(b, @window_ms, limit)
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

      assert log =~ "fail-open"
      # PII-safe: only the non-identifying bucket FAMILY is logged; the unique
      # id suffix is stripped, so the full bucket never reaches the log.
      assert log =~ "family=test:failopen"
      refute log =~ b
    end

    test "an arithmetic fault (window_ms = 0) also fails OPEN rather than crashing the caller" do
      b = bucket("failopen-arith")

      log =
        capture_log(fn ->
          assert {:allow, 0} = Postgres.check_rate(b, 0, 5)
        end)

      assert log =~ "fail-open"
    end
  end

  describe "TC-38.2.1: default-off safety (ETS by default + single-node parity)" do
    test "the PRODUCTION default resolver yields the node-local ETS Hammer impl" do
      # AC-38.2.3 default-safety: with `:rate_limiter` unset (prod/dev), every
      # caller falls back to the node-local ETS impl. Assert against the REAL
      # production constant `Loopctl.RateLimiter.default_impl/0` — the exact value
      # `impl/0` returns when the key is absent — NOT a hardcoded literal. If the
      # default were changed to Postgres (or the fallback deleted) this fails, so
      # it is not tautological: it exercises the shipped resolver.
      assert Loopctl.RateLimiter.default_impl() == Loopctl.RateLimiter.Hammer

      # The resolver reads the config key: `config/test.exs` sets the mock, so
      # `impl/0` returns it — proving the seam both the web plug and admission use
      # is config-driven (swap the key → swap the impl fleet-wide, no call-site
      # edit).
      assert Loopctl.RateLimiter.impl() == Loopctl.MockRateLimiter

      # Both concrete impls satisfy the shared behaviour, so the DI seam is
      # swap-safe in either direction.
      Code.ensure_loaded!(Loopctl.RateLimiter.Hammer)
      Code.ensure_loaded!(Loopctl.RateLimiter.Postgres)
      assert function_exported?(Loopctl.RateLimiter.Hammer, :check_rate, 3)
      assert function_exported?(Loopctl.RateLimiter.Postgres, :check_rate, 3)
    end

    test "single-node results are IDENTICAL to the fixed-window contract the ETS impl honors" do
      # AC-38.2.3: "single-node results are identical." The node-local ETS
      # (Hammer) contract is a fixed-window post-increment counter that allows
      # while `count <= limit`. Assert the Postgres impl reproduces that EXACT
      # allow/deny sequence single-node — so selecting it changes only the STORE
      # (per-node → shared), never the per-request decision a limit yields. This
      # runs the real `Postgres.check_rate/3`, so deleting it fails the test.
      pin_clock()
      b = bucket("parity")
      limit = 4

      results = for _ <- 1..7, do: Postgres.check_rate(b, @window_ms, limit)

      assert results == [
               {:allow, 1},
               {:allow, 2},
               {:allow, 3},
               {:allow, 4},
               {:deny, 4},
               {:deny, 4},
               {:deny, 4}
             ]
    end
  end
end
