defmodule Loopctl.Egress.PinCacheTest do
  @moduledoc """
  US-41.4 (AC-41.4.12) — the pin cache's INVALIDATION guarantees and the
  refresher's resource behaviour.

  Every test here is a REGRESSION from review: invalidation was silently undone by
  a concurrent refresh (and by the marking read-through), name-allowlisted hosts
  flapped into `:pin_stale` on every cycle, entries were never evicted, and an
  unscoped `refresh_now/0` mutated neighbouring async tests' entries.
  """

  use Loopctl.DataCase, async: true

  import Mox

  alias Loopctl.Egress
  alias Loopctl.Egress.PinCache
  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Test.AllowlistSource

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    on_exit(fn -> PinCache.invalidate_tenant(tenant.id) end)
    {:ok, tenant: tenant, scope: Scope.new(tenant.id)}
  end

  describe "a cache that cannot store must degrade to a MISS, not to a different answer" do
    test "put returns a FULLY SHAPED entry even when the write is dropped",
         %{tenant: t, scope: scope} do
      # A dropped write is the only outcome a caller may observe from a storage
      # failure. The entry itself must be identical either way: `put/5` used to
      # rescue around its whole body and hand back a map missing :host,
      # :tenant_id, :scope_key and :expires_at, so what a caller got depended on
      # whether the ETS table happened to exist — and reading a dropped key off it
      # raises KeyError, turning a cache outage into a classification failure.
      key = Scope.key(scope)
      attrs = %{base_verdict: :public, from_allowlist: false, ips: [], purposes: []}

      stored = PinCache.put(t.id, key, "shape.example.com", attrs, generation: nil)

      # Same call, but with a generation an invalidation has already superseded:
      # admission is refused and nothing lands.
      generation = PinCache.generation(t.id)
      :ok = PinCache.invalidate_tenant(t.id)
      dropped = PinCache.put(t.id, key, "shape.example.com", attrs, generation: generation)

      assert PinCache.fetch(t.id, key, "shape.example.com") == :miss

      assert Map.keys(dropped) |> Enum.sort() == Map.keys(stored) |> Enum.sort()
      assert dropped.host == "shape.example.com"
      assert dropped.tenant_id == t.id
      assert dropped.scope_key == key
      assert is_integer(dropped.expires_at)
      assert dropped.base_verdict == :public
    end
  end

  describe "per-tenant resident bound" do
    test "one tenant cannot crowd the shared table; a neighbour still gets admitted",
         %{tenant: t, scope: scope} do
      neighbour = fixture(:tenant)
      on_exit(fn -> PinCache.invalidate_tenant(neighbour.id) end)

      key = Scope.key(scope)
      cap = PinCache.max_entries_per_tenant()
      attrs = %{base_verdict: :public, from_allowlist: false, ips: [], purposes: []}

      for i <- 1..cap, do: PinCache.put(t.id, key, "h#{i}.example.com", attrs)

      assert PinCache.resident(t.id) == cap

      # Past the cap a NEW key is refused admission...
      PinCache.put(t.id, key, "overflow.example.com", attrs)
      assert PinCache.fetch(t.id, key, "overflow.example.com") == :miss

      # ...while an EXISTING key still refreshes (the documented behaviour of the
      # global cap, applied per tenant).
      assert {:ok, entry} = PinCache.fetch(t.id, key, "h1.example.com")
      assert entry.base_verdict == :public
      PinCache.put(t.id, key, "h1.example.com", %{attrs | base_verdict: :denylisted})
      assert {:ok, %{base_verdict: :denylisted}} = PinCache.fetch(t.id, key, "h1.example.com")

      # And the whole point: the neighbour is untouched by it.
      neighbour_key = Scope.key(Scope.new(neighbour.id))
      PinCache.put(neighbour.id, neighbour_key, "n1.example.com", attrs)
      assert {:ok, _} = PinCache.fetch(neighbour.id, neighbour_key, "n1.example.com")
    end

    test "invalidation frees the tenant's headroom immediately", %{tenant: t, scope: scope} do
      key = Scope.key(scope)
      cap = PinCache.max_entries_per_tenant()
      attrs = %{base_verdict: :public, from_allowlist: false, ips: [], purposes: []}

      for i <- 1..cap, do: PinCache.put(t.id, key, "h#{i}.example.com", attrs)
      :ok = PinCache.invalidate_tenant(t.id)

      assert PinCache.resident(t.id) == 0
      PinCache.put(t.id, key, "after.example.com", attrs)
      assert {:ok, _} = PinCache.fetch(t.id, key, "after.example.com")
    end

    test "deleting an entry returns its slot", %{tenant: t, scope: scope} do
      key = Scope.key(scope)
      attrs = %{base_verdict: :public, from_allowlist: false, ips: [], purposes: []}

      PinCache.put(t.id, key, "one.example.com", attrs)
      assert PinCache.resident(t.id) == 1

      :ok = PinCache.delete(t.id, key, "one.example.com")
      assert PinCache.resident(t.id) == 0

      # A delete of an absent key must not drive the counter negative and hand the
      # tenant headroom it did not earn.
      :ok = PinCache.delete(t.id, key, "one.example.com")
      assert PinCache.resident(t.id) == 0
    end

    test "the sweep reconciles the counter to the true resident count",
         %{tenant: t, scope: scope} do
      key = Scope.key(scope)
      attrs = %{base_verdict: :public, from_allowlist: false, ips: [], purposes: []}

      PinCache.put(t.id, key, "live.example.com", attrs)

      # `expires_at` is a MONOTONIC stamp, typically NEGATIVE on Linux — a literal
      # 0 is in the FUTURE and would never be swept.
      already_expired = System.monotonic_time(:millisecond) - 1_000

      PinCache.put(
        t.id,
        key,
        "reconcile.example.com",
        Map.put(attrs, :expires_at, already_expired)
      )

      assert PinCache.resident(t.id) == 2

      PinCache.refresh_now(t.id)

      # The expired one was swept; the counter says so.
      assert PinCache.fetch(t.id, key, "reconcile.example.com") == :miss
      assert PinCache.resident(t.id) == 1
    end
  end

  describe "invalidation beats a concurrent write (generation counter)" do
    test "a put whose captured generation was invalidated is DROPPED", %{tenant: t, scope: scope} do
      key = Scope.key(scope)

      # A writer captures the generation, then does slow work (DB read / DNS)...
      generation = PinCache.generation(t.id)

      # ... during which a revocation / marking change invalidates the tenant ...
      :ok = PinCache.invalidate_tenant(t.id)

      # ... and only THEN writes. The stale write must not resurrect anything.
      PinCache.put(
        t.id,
        key,
        "ollama.example.com",
        %{base_verdict: :public, ips: [], purposes: []},
        generation: generation
      )

      assert PinCache.fetch(t.id, key, "ollama.example.com") == :miss

      # A writer that captured the CURRENT generation still caches normally.
      PinCache.put(
        t.id,
        key,
        "ollama.example.com",
        %{base_verdict: :public, ips: [], purposes: []},
        generation: PinCache.generation(t.id)
      )

      assert {:ok, _} = PinCache.fetch(t.id, key, "ollama.example.com")
    end

    test "a refresh pass in flight cannot resurrect an invalidated entry",
         %{tenant: t, scope: scope} do
      key = Scope.key(scope)
      test_pid = self()

      stub(Loopctl.MockDnsResolver, :resolve, fn "slow.example.com" ->
        # The invalidation lands WHILE the (blocking) resolution is in flight —
        # exactly the up-to-6s window `revalidate/1` opens.
        send(test_pid, :resolving)
        PinCache.invalidate_local(t.id)
        {:ok, [{203, 0, 113, 10}]}
      end)

      PinCache.put(t.id, key, "slow.example.com", %{
        base_verdict: :public,
        from_allowlist: false,
        ips: [{203, 0, 113, 10}],
        purposes: ["inference"],
        used: true
      })

      :ok = PinCache.mark_due(t.id, key, "slow.example.com")
      PinCache.refresh_now(t.id)

      assert_received :resolving
      assert PinCache.fetch(t.id, key, "slow.example.com") == :miss
    end

    test "an ENABLE landing during the marking read is not masked for the TTL",
         %{tenant: t, scope: scope} do
      key = Scope.key(scope)

      # The exact losing interleaving: the marking read-through reads the DB
      # (local_only: false), the ENABLE then commits and invalidates, and only THEN
      # the read-through writes its cache entry. Caching that `false` would be a
      # ten-minute activation hole while the posture report attests the tightened
      # posture — the hole the pin cache exists to close.
      generation = PinCache.generation(t.id)
      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.put(t.id, key, :__marking__, %{local_only: false}, generation: generation)

      assert PinCache.fetch(t.id, key, :__marking__) == :miss

      assert {:error, :egress_blocked, _} =
               Policy.check(scope, "https://api.openai.com/v1/embeddings", :inference)
    end
  end

  describe "the refresher's resource behaviour" do
    test "a name-allowlisted host revalidates instead of flapping to :pin_stale",
         %{tenant: t, scope: scope} do
      AllowlistSource.put(["ollama.internal"])
      on_exit(&AllowlistSource.clear/0)

      stub(Loopctl.MockDnsResolver, :resolve, fn "ollama.internal" -> {:ok, [{10, 9, 9, 9}]} end)

      {:ok, _} = Egress.enable_local_only(t.id, nil, acknowledge: true)
      PinCache.invalidate_tenant(t.id)

      assert {:ok, _} = Policy.check(scope, "http://ollama.internal:11434/v1", :inference)

      :ok = PinCache.mark_due(t.id, Scope.key(scope), "ollama.internal")
      PinCache.refresh_now(t.id)

      # The carve-out was granted BY NAME, so revalidation must re-check the NAME.
      # Checking only the address form marked it pin_stale with a fresh TTL every
      # cycle, snoozing every job for that tenant.
      {:ok, entry} = PinCache.fetch(t.id, Scope.key(scope), "ollama.internal")
      refute entry.pin_stale
      assert {:ok, _} = Policy.check(scope, "http://ollama.internal:11434/v1", :inference)
    end

    test "an expired entry is EVICTED by the pass, not re-resolved forever",
         %{tenant: t, scope: scope} do
      key = Scope.key(scope)

      PinCache.put(t.id, key, "gone.example.com", %{
        base_verdict: :public,
        from_allowlist: false,
        ips: [{203, 0, 113, 10}],
        purposes: [],
        used: true,
        expires_at: System.monotonic_time(:millisecond) - 1
      })

      # A resolve here would mean the refresher is still working an expired entry.
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> raise "expired entry was re-resolved" end)

      PinCache.refresh_now(t.id)

      assert PinCache.fetch(t.id, key, "gone.example.com") == :miss
      assert Enum.all?(PinCache.all(), &(&1.host != "gone.example.com"))
    end

    test "an entry nobody looked up since the last pass is NOT re-resolved",
         %{tenant: t, scope: scope} do
      key = Scope.key(scope)

      PinCache.put(t.id, key, "idle.example.com", %{
        base_verdict: :public,
        from_allowlist: false,
        ips: [{203, 0, 113, 10}],
        purposes: [],
        used: false,
        # DUE, but untouched since the last pass. (`mark_due/3` cannot be used here:
        # it reads through `fetch/3`, which is exactly what flags an entry as used.)
        refresh_at: System.monotonic_time(:millisecond) - 1
      })

      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> raise "idle entry was re-resolved" end)

      assert PinCache.refresh_now(t.id) == 0

      # A lookup flags it used, and the NEXT pass does revalidate it.
      assert {:ok, _} = PinCache.fetch(t.id, key, "idle.example.com")
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{203, 0, 113, 10}]} end)
      assert PinCache.refresh_now(t.id) == 1
    end

    test "refresh_now/1 touches ONLY the given tenant's entries", %{tenant: t, scope: scope} do
      neighbour = fixture(:tenant)
      neighbour_scope = Scope.new(neighbour.id)
      on_exit(fn -> PinCache.invalidate_tenant(neighbour.id) end)

      for {tenant_id, key} <- [
            {t.id, Scope.key(scope)},
            {neighbour.id, Scope.key(neighbour_scope)}
          ] do
        PinCache.put(tenant_id, key, "shared.example.com", %{
          base_verdict: :public,
          from_allowlist: false,
          ips: [{203, 0, 113, 10}],
          purposes: [],
          used: true
        })

        :ok = PinCache.mark_due(tenant_id, key, "shared.example.com")
      end

      # The neighbour's address set "changed" — under an UNSCOPED pass this stub
      # would flip the neighbour's entry to pin_stale through THIS test's process.
      stub(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{198, 51, 100, 7}]} end)

      assert PinCache.refresh_now(t.id) == 1

      {:ok, mine} = PinCache.fetch(t.id, Scope.key(scope), "shared.example.com")
      assert mine.pin_stale

      {:ok, theirs} =
        PinCache.fetch(neighbour.id, Scope.key(neighbour_scope), "shared.example.com")

      refute theirs.pin_stale
    end
  end
end
