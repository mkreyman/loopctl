defmodule Loopctl.RateLimiterTest do
  @moduledoc """
  US-38.2 — the DI resolver's robust gate helpers.

  `within_limit?/3` (fail-OPEN, capacity gates) and `gate_ok?/3` (fail-CLOSED,
  anti-abuse/brute-force gates) must normalise EVERY limiter outcome — allow,
  deny, the behaviour's permitted `{:error, _}`, an unexpected shape, and a
  raised exception — to a boolean without ever crashing the caller. These prove
  the fix for the bare-`case` CaseClauseError→500 finding and the fail-open
  blast-radius finding (a store fault must not unlock a security gate).
  """
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  @window_ms 60_000

  describe "within_limit?/3 (fail-OPEN capacity gate)" do
    test "true within the limit, false when denied" do
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:allow, 3} end)
      assert Loopctl.RateLimiter.within_limit?("b", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:deny, 5} end)
      refute Loopctl.RateLimiter.within_limit?("b", @window_ms, 5)
    end

    test "fails OPEN (true) on {:error, _}, an unexpected shape, and a raised exception" do
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:error, :boom} end)
      assert Loopctl.RateLimiter.within_limit?("key:x", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> :nonsense end)
      assert Loopctl.RateLimiter.within_limit?("key:x", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> raise "db down" end)
      assert Loopctl.RateLimiter.within_limit?("key:x", @window_ms, 5)
    end

    test "honours the {:allow, 0} fail-open sentinel as allowed" do
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:allow, 0} end)
      assert Loopctl.RateLimiter.within_limit?("b", @window_ms, 5)
    end
  end

  describe "gate_ok?/3 (fail-CLOSED security gate)" do
    test "true only on a genuine positive-count allow" do
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:allow, 1} end)
      assert Loopctl.RateLimiter.gate_ok?("api_signup:ip:1.2.3.4", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:deny, 5} end)
      refute Loopctl.RateLimiter.gate_ok?("api_signup:ip:1.2.3.4", @window_ms, 5)
    end

    test "fails CLOSED (false) on {:error, _}, an unexpected shape, and a raised exception" do
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:error, :boom} end)
      refute Loopctl.RateLimiter.gate_ok?("api_signup:ip:1.2.3.4", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> :nonsense end)
      refute Loopctl.RateLimiter.gate_ok?("api_signup:ip:1.2.3.4", @window_ms, 5)

      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> raise "db down" end)
      refute Loopctl.RateLimiter.gate_ok?("api_signup:ip:1.2.3.4", @window_ms, 5)
    end

    test "treats the {:allow, 0} Postgres fail-open sentinel as DENIED (does not unlock the gate)" do
      # This is the blast-radius fix: under RATE_LIMITER=postgres a DB fault
      # returns {:allow, 0}; a security gate must NOT admit on it.
      expect(Loopctl.MockRateLimiter, :check_rate, fn _b, _w, _l -> {:allow, 0} end)
      refute Loopctl.RateLimiter.gate_ok?("signup:webauthn:key", @window_ms, 20)
    end
  end
end
