defmodule Loopctl.ReplicaReadinessTest do
  @moduledoc """
  US-38.1 / AC-38.1.2 — the boot readiness probe that makes "fail LOUD at boot" REAL for an
  unreachable read replica (rather than booting green and 500-ing every heavy read at query
  time). The pure decision + retry helpers are exercised here without an actually-unreachable
  DB; the no-op default path is verified against the real (replica-unconfigured) test env.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ReplicaReadiness

  describe "assert_reachable!/0 (no replica configured — the test/default env)" do
    test "is a NO-OP when no distinct replica is configured (never probes, never raises)" do
      # replica_configured?/0 is false in test (no REPLICA_DATABASE_URL), so this must short
      # circuit to :ok without touching the pool.
      refute Loopctl.DbCapacity.replica_configured?()
      assert ReplicaReadiness.assert_reachable!() == :ok
    end
  end

  describe "raise_if_unreachable!/1 (the fail-loud decision, pure)" do
    test "a reachable probe (:ok) returns :ok" do
      assert ReplicaReadiness.raise_if_unreachable!(:ok) == :ok
    end

    test "an unreachable probe RAISES loud with a diagnostic (fail-loud-at-boot)" do
      err =
        assert_raise RuntimeError, fn ->
          ReplicaReadiness.raise_if_unreachable!({:error, :econnrefused})
        end

      assert Exception.message(err) =~ "REPLICA_DATABASE_URL"
      assert Exception.message(err) =~ "econnrefused"
      assert Exception.message(err) =~ "Failing loud"
    end
  end

  describe "probe/3 (bounded retry to absorb a cold pool warming up)" do
    test "returns :ok immediately on a reachable probe" do
      assert ReplicaReadiness.probe(fn -> :ok end, 5, 0) == :ok
    end

    test "returns the error after exhausting attempts on a persistently-unreachable probe" do
      assert ReplicaReadiness.probe(fn -> {:error, :timeout} end, 3, 0) == {:error, :timeout}
    end

    test "retries a transient failure and succeeds once the pool becomes reachable" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      probe = fn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        if n >= 3, do: :ok, else: {:error, :not_ready}
      end

      # Fails on attempts 1 and 2, succeeds on 3 — within the 5-attempt budget.
      assert ReplicaReadiness.probe(probe, 5, 0) == :ok
      assert Agent.get(counter, & &1) == 3
    end

    test "a probe that never recovers within the budget returns the last error" do
      assert ReplicaReadiness.probe(fn -> {:error, :down} end, 2, 0) == {:error, :down}
    end
  end
end
