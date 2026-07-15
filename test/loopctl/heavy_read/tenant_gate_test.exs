defmodule Loopctl.HeavyRead.TenantGateTest do
  @moduledoc """
  US-37.5 — per-tenant, cost-weighted, node-local in-flight limiter on the HeavyRead
  pool.

  Exercises the pure core (`acquire/3` / `release/2`) against EXPLICIT low caps and
  explicit heavy-vs-light weights, so no global config is mutated (no
  `Application.put_env`) and the async, VM-wide shared counters never collide (each
  test uses fresh random `tenant_id`s). Covers the per-tenant cap (AC-37.5.1), cost
  weighting (AC-37.5.2), over-cap shed + release (AC-37.5.3), tenant isolation +
  fairness outcome (AC-37.5.4), and the env-driven defaults + fail-open (AC-37.5.5).
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.DbCapacity
  alias Loopctl.HeavyRead.TenantGate

  describe "acquire/3 per-tenant concurrency cap (AC-37.5.1)" do
    test "a tenant holding K slots is shed on the K+1th, while another tenant can still acquire" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()
      cap = 2

      # A holds K=2 (weight 1 each) — both admitted.
      assert TenantGate.acquire(tenant_a, 1, cap) == :ok
      assert TenantGate.acquire(tenant_a, 1, cap) == :ok

      # The K+1th for A is shed — A cannot exceed its slice.
      assert TenantGate.acquire(tenant_a, 1, cap) == {:error, :heavy_read_overloaded}

      # B is a different tenant: its counter is independent, so it still acquires.
      assert TenantGate.acquire(tenant_b, 1, cap) == :ok

      assert TenantGate.count(tenant_a) == 2
      assert TenantGate.count(tenant_b) == 1
    end

    test "the shed acquire leaves NO budget reserved (the undo is atomic)" do
      tenant = Ecto.UUID.generate()
      cap = 1

      assert TenantGate.acquire(tenant, 1, cap) == :ok
      assert TenantGate.acquire(tenant, 1, cap) == {:error, :heavy_read_overloaded}

      # The shed acquire's transient +1 was undone: the tenant still holds exactly 1.
      assert TenantGate.count(tenant) == 1
    end
  end

  describe "cost weighting (AC-37.5.2)" do
    test "a heavier read consumes more budget — fewer concurrent heavy than light within one cap" do
      cap = 4
      heavy = TenantGate.heavy_weight()
      light = TenantGate.light_weight()

      assert heavy > light, "heavy reads must cost strictly more than light ones"

      # HEAVY: with weight #{2} and cap 4, only 2 concurrent heavy reads fit (2+2=4);
      # the 3rd (would be 6 > 4) is shed.
      heavy_tenant = Ecto.UUID.generate()
      assert TenantGate.acquire(heavy_tenant, heavy, cap) == :ok
      assert TenantGate.acquire(heavy_tenant, heavy, cap) == :ok
      assert TenantGate.acquire(heavy_tenant, heavy, cap) == {:error, :heavy_read_overloaded}

      # LIGHT: with weight 1 and the SAME cap 4, four concurrent light reads fit; the
      # 5th is shed. Strictly MORE concurrent light reads than heavy within one budget.
      light_tenant = Ecto.UUID.generate()
      for _ <- 1..cap, do: assert(TenantGate.acquire(light_tenant, light, cap) == :ok)
      assert TenantGate.acquire(light_tenant, light, cap) == {:error, :heavy_read_overloaded}
    end

    test "weight_for/1 classifies known heavy endpoints above light/unknown ones" do
      heavy = TenantGate.heavy_weight()
      light = TenantGate.light_weight()

      for endpoint <- [
            :vector_search,
            :semantic_search,
            :memory_recall,
            :novelty,
            :suggested_links,
            :distant_pairs,
            :distant_pairs_bridge
          ] do
        assert TenantGate.weight_for(endpoint) == heavy
      end

      for endpoint <- [:change_feed, :enumeration, :ingestion_jobs, :sth_incremental, nil] do
        assert TenantGate.weight_for(endpoint) == light
      end
    end
  end

  describe "over-cap shed + release (AC-37.5.3)" do
    test "an over-cap tenant is shed with :heavy_read_overloaded while another tenant is served" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()
      cap = 2

      for _ <- 1..cap, do: assert(TenantGate.acquire(tenant_a, 1, cap) == :ok)
      # A is saturated → shed with the exact tagged error the callers map to a
      # graceful response (keyword fallback / 429), NOT a pool-exhaustion crash.
      assert TenantGate.acquire(tenant_a, 1, cap) == {:error, :heavy_read_overloaded}

      # B — sharing the same node-local gate — is unaffected and gets service.
      assert TenantGate.acquire(tenant_b, 1, cap) == :ok
    end

    test "releasing a slot lets a previously-shed tenant acquire again" do
      tenant = Ecto.UUID.generate()
      cap = 1

      assert TenantGate.acquire(tenant, 1, cap) == :ok
      assert TenantGate.acquire(tenant, 1, cap) == {:error, :heavy_read_overloaded}

      # Free the held slot; the tenant now fits again.
      assert TenantGate.release(tenant, 1) == :ok
      assert TenantGate.count(tenant) == 0
      assert TenantGate.acquire(tenant, 1, cap) == :ok
    end

    test "release floors at 0 — a stray/extra release never drives the counter negative" do
      tenant = Ecto.UUID.generate()

      assert TenantGate.release(tenant, 5) == :ok
      assert TenantGate.count(tenant) == 0

      assert TenantGate.acquire(tenant, 1, 1) == :ok
      # Two releases for one acquire: the second floors at 0, never negative (which
      # would inflate the effective cap).
      assert TenantGate.release(tenant, 1) == :ok
      assert TenantGate.release(tenant, 1) == :ok
      assert TenantGate.count(tenant) == 0
    end
  end

  describe "tenant isolation + fairness outcome (AC-37.5.4)" do
    test "tenant A's in-flight count NEVER includes tenant B's" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()
      cap = 3

      # A saturates its own slice.
      for _ <- 1..cap, do: assert(TenantGate.acquire(tenant_a, 1, cap) == :ok)
      # A pile of B's acquisitions on the same node must be invisible to A's counter.
      for _ <- 1..cap, do: assert(TenantGate.acquire(tenant_b, 1, cap) == :ok)

      assert TenantGate.count(tenant_a) == cap
      assert TenantGate.count(tenant_b) == cap
      # A's decision reads only A's count — A is capped...
      assert TenantGate.acquire(tenant_a, 1, cap) == {:error, :heavy_read_overloaded}
    end

    test "with A saturating its cap, B makes progress (outcome class — B is not starved)" do
      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()
      cap = 2

      # A continuously saturates its slice and is shed on further attempts.
      for _ <- 1..cap, do: assert(TenantGate.acquire(tenant_a, 1, cap) == :ok)
      assert TenantGate.acquire(tenant_a, 1, cap) == {:error, :heavy_read_overloaded}
      assert TenantGate.acquire(tenant_a, 1, cap) == {:error, :heavy_read_overloaded}

      # OUTCOME class (not exact instantaneous counts): B still acquires AND releases
      # its full cap repeatedly while A stays capped — B makes progress, unstarved.
      for _ <- 1..5 do
        assert TenantGate.acquire(tenant_b, 1, cap) == :ok
        assert TenantGate.release(tenant_b, 1) == :ok
      end

      # A releasing one of its held slots lets A make progress too — the gate is a
      # latency bound, never a permanent wedge.
      assert TenantGate.release(tenant_a, 1) == :ok
      assert TenantGate.acquire(tenant_a, 1, cap) == :ok
    end
  end

  describe "env-driven caps/weights + fail-open (AC-37.5.5)" do
    test "the default per-tenant slice K is < the heavy-read pool size and >= 1" do
      k = DbCapacity.heavy_read_tenant_slice()
      pool = DbCapacity.heavy_read_budget().pool

      assert k >= 1
      assert k < pool, "K (#{k}) must be < pool (#{pool}) so no tenant can take the whole pool"
      # K must admit at least one HEAVY read (cap >= heavy weight), else a single heavy
      # read would always shed — the gate would starve a tenant to zero heavy reads.
      assert k >= TenantGate.heavy_weight()
    end

    test "cap/0 resolves a positive integer from config (documented default on a miss)" do
      assert is_integer(TenantGate.cap())
      assert TenantGate.cap() > 0
    end

    test "acquire fails OPEN (allows the read) when the limiter faults — a broken gate never blocks" do
      tenant = Ecto.UUID.generate()
      # A table that was never created: :ets.update_counter raises, so the rescue must
      # fail OPEN with :ok rather than blocking the read. Uses the table-parameterized
      # core so the shared, VM-wide production table is untouched.
      missing = :"loopctl_heavy_read_inflight_missing_#{System.unique_integer([:positive])}"

      assert TenantGate.acquire(tenant, 1, 1, missing) == :ok
      # release + count on a missing table are also fail-safe (no crash).
      assert TenantGate.release(tenant, 1, missing) == :ok
      assert TenantGate.count(tenant, missing) == 0
    end
  end
end
