defmodule Loopctl.Auth.ApiKeyCacheTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache
  alias Loopctl.Workers.RevokeExpiredDispatchesWorker

  import Ecto.Query
  import ExUnit.CaptureLog

  # The ETS owner runs as part of the app supervision tree in the test env, so the
  # table already exists — no start_supervised needed (mirrors SettingsCache tests).
  # async: true is safe because every test uses fresh api_key fixtures = unique
  # key_hash keys, so the shared named table is never contended across tests.

  describe "fetch/2 + put + invalidate (ETS unit)" do
    test "fetch on an unknown key_hash is a miss" do
      assert ApiKeyCache.fetch(Auth.hash_key("lc_never-seen")) == :miss
    end

    test "put then fetch returns the stored struct as a hit" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      :ok = ApiKeyCache.put(ak.key_hash, ak)

      assert {:ok, %ApiKey{} = cached} = ApiKeyCache.fetch(ak.key_hash)
      assert cached.id == ak.id
    end

    test "invalidate deletes the entry (back to a miss)" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      :ok = ApiKeyCache.put(ak.key_hash, ak)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      :ok = ApiKeyCache.invalidate(ak.key_hash)
      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end

    test "invalidate BUMPS the generation (monotonic authority)" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      gen0 = ApiKeyCache.generation(ak.key_hash)

      :ok = ApiKeyCache.invalidate(ak.key_hash)
      gen1 = ApiKeyCache.generation(ak.key_hash)
      assert gen1 > gen0

      :ok = ApiKeyCache.invalidate(ak.key_hash)
      assert ApiKeyCache.generation(ak.key_hash) > gen1
    end

    test "a put stamped with an older generation is a MISS (stale repopulation rejected)" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      stale_gen = ApiKeyCache.generation(ak.key_hash)
      :ok = ApiKeyCache.invalidate(ak.key_hash)
      assert ApiKeyCache.generation(ak.key_hash) > stale_gen

      # A LATE read-through repopulation stamped with the pre-invalidation
      # generation (reader snapshotted before the writer's invalidate) is inserted
      # but must NEVER be trusted — fetch rejects it as stale.
      :ok = ApiKeyCache.put(ak.key_hash, ak, stale_gen)
      assert ApiKeyCache.fetch(ak.key_hash) == :miss

      # A put stamped with the CURRENT generation IS served.
      :ok = ApiKeyCache.put(ak.key_hash, ak, ApiKeyCache.generation(ak.key_hash))
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash)
    end

    test "reset/1 is an alias for invalidate/1" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      :ok = ApiKeyCache.put(ak.key_hash, ak)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      :ok = ApiKeyCache.reset(ak.key_hash)
      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end
  end

  describe "verify_api_key/1 read-through cache" do
    # TC-33.3.1
    test "second request is served from ETS: a direct DB mutation is NOT seen until invalidation" do
      {raw, ak} = fixture(:api_key, role: :agent, name: "original-name")

      # First verify populates the cache read-through.
      assert {:ok, %ApiKey{name: "original-name"}} = Auth.verify_api_key(raw)

      # Mutate a NON-auth field DIRECTLY in the DB (bypassing any invalidation).
      {1, _} =
        from(k in ApiKey, where: k.id == ^ak.id)
        |> AdminRepo.update_all(set: [name: "mutated-directly"])

      # Still the cached name — proves the 2nd verify hit ETS, not the DB.
      assert {:ok, %ApiKey{name: "original-name"}} = Auth.verify_api_key(raw)

      # After invalidation the next verify repopulates from the DB and sees it.
      :ok = ApiKeyCache.invalidate(ak.key_hash)
      assert {:ok, %ApiKey{name: "mutated-directly"}} = Auth.verify_api_key(raw)
    end

    test "the resolved struct carries :tenant preloaded (custody_halted_at) on hit and miss" do
      {raw, _ak} = fixture(:api_key, role: :agent)

      # Miss path.
      assert {:ok, %ApiKey{tenant: %Loopctl.Tenants.Tenant{}}} = Auth.verify_api_key(raw)
      # Hit path.
      assert {:ok, %ApiKey{tenant: tenant}} = Auth.verify_api_key(raw)
      assert %Loopctl.Tenants.Tenant{} = tenant
      assert Map.has_key?(tenant, :custody_halted_at)
    end
  end

  describe "SECURITY — invalidate on revoke (TC-33.3.2 RELEASE GATE)" do
    test "a revoked key is rejected on the VERY NEXT request, not after the TTL" do
      {raw, ak} = fixture(:api_key, role: :agent)

      # Populate the cache.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)

      # Revoke via the real revoke path (which invalidates in-band).
      {:ok, _} = Auth.revoke_api_key(ak)

      # Immediately unauthorized — never the stale valid struct.
      assert Auth.verify_api_key(raw) == {:error, :unauthorized}
    end

    test "the dispatch-cascade revoke path invalidates each revoked key_hash" do
      tenant = fixture(:tenant)

      # A dispatch with a linked api_key, then revoke via the cascade path.
      {raw, ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)
      dispatch = dispatch_for(tenant.id, ak.id)

      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)

      {:ok, _count} = Loopctl.Dispatches.revoke(tenant.id, dispatch.id)

      assert Auth.verify_api_key(raw) == {:error, :unauthorized}
    end

    test "the RevokeExpiredDispatchesWorker release-gate path busts the cache for expired dispatch keys" do
      tenant = fixture(:tenant)

      # A key linked to a dispatch that is already past its expiry.
      {raw, ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)
      past = DateTime.add(DateTime.utc_now(), -120, :second)
      _dispatch = dispatch_for(tenant.id, ak.id, past)

      # Populate the cache read-through.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)

      # The cron worker revokes the expired dispatch + its api_key and MUST bust the
      # cache in-band (AC-33.3.2) — deleting worker line 56 would leave this green
      # only because of the assertion below.
      assert :ok = RevokeExpiredDispatchesWorker.perform(%Oban.Job{args: %{}})

      # Immediately unauthorized on the very next request, not after the TTL.
      assert Auth.verify_api_key(raw) == {:error, :unauthorized}
    end
  end

  describe "SECURITY — invalidate on rotate/mutate (TC-33.3.3)" do
    test "a rotation grace-expiry in the past takes effect immediately (not after TTL)" do
      {raw, ak} = fixture(:api_key, role: :agent)

      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)

      # Rotation sets an expiry on the old key; a past expiry means already expired.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = Auth.expire_api_key(ak, past)

      assert Auth.verify_api_key(raw) == {:error, :unauthorized}
    end

    test "an expiry mutation is reflected on the next request once the mutation invalidates" do
      {raw, ak} = fixture(:api_key, role: :agent)

      # No expiry initially -> caches with expires_at nil.
      assert {:ok, %ApiKey{expires_at: nil}} = Auth.verify_api_key(raw)

      # A future rotation expiry set DIRECTLY (models the expire/rotate mutation)
      # WITHOUT invalidating — the key is still valid, but the cached struct is stale.
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {1, _} =
        from(k in ApiKey, where: k.id == ^ak.id)
        |> AdminRepo.update_all(set: [expires_at: future])

      # Still cached with the old (nil) expiry until the mutation path invalidates.
      assert {:ok, %ApiKey{expires_at: nil}} = Auth.verify_api_key(raw)

      # The mutation path busts the key_hash entry -> next verify reflects the change.
      :ok = ApiKeyCache.invalidate_cluster(ak.key_hash)
      assert {:ok, %ApiKey{expires_at: %DateTime{}}} = Auth.verify_api_key(raw)
    end
  end

  describe "defense-in-depth bounded TTL (TC-33.3.4)" do
    test "TTL self-heals a MISSED invalidation: an expired entry re-validates against the DB" do
      {raw, ak} = fixture(:api_key, role: :agent)

      # Populate the cache.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, cached} = ApiKeyCache.fetch(ak.key_hash)

      # Simulate a MISSED invalidation path: revoke in the DB WITHOUT busting the
      # cache. The stale cached entry would still authenticate on a HIT...
      {1, _} =
        from(k in ApiKey, where: k.id == ^ak.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      # ...so force the entry past its TTL (matching generation — only the TTL can
      # reject it), modelling "advance past the bounded TTL".
      gen = ApiKeyCache.generation(ak.key_hash)
      past = System.monotonic_time(:millisecond) - 1
      true = :ets.insert(ApiKeyCache.table_name(), {ak.key_hash, cached, gen, past})

      # The TTL backstop re-validates against the DB -> the revoke is honored.
      assert Auth.verify_api_key(raw) == {:error, :unauthorized}
    end

    test "an entry past its TTL is a MISS even when its generation still matches" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      gen = ApiKeyCache.generation(ak.key_hash)

      past = System.monotonic_time(:millisecond) - 1
      true = :ets.insert(ApiKeyCache.table_name(), {ak.key_hash, ak, gen, past})

      assert ApiKeyCache.fetch(ak.key_hash) == :miss

      # A fresh-expiry entry with the same generation IS served.
      :ok = ApiKeyCache.put(ak.key_hash, ak, gen)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash)
    end

    test "the periodic sweep actively evicts an expired entry" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      gen = ApiKeyCache.generation(ak.key_hash)

      past = System.monotonic_time(:millisecond) - 1
      true = :ets.insert(ApiKeyCache.table_name(), {ak.key_hash, ak, gen, past})

      send(Process.whereis(ApiKeyCache), :sweep)
      _ = :sys.get_state(ApiKeyCache)

      assert :ets.lookup(ApiKeyCache.table_name(), ak.key_hash) == []
    end
  end

  describe "generation-entry memory bound (technical-notes)" do
    test "an idle generation entry is reaped by the sweep, capping memory" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      # The first invalidation creates the {:gen, key_hash} counter entry.
      :ok = ApiKeyCache.invalidate(ak.key_hash)

      assert [{{:gen, _}, _gen, _reap}] =
               :ets.lookup(ApiKeyCache.table_name(), {:gen, ak.key_hash})

      # Force its reap deadline into the past (models "idle beyond the bump grace").
      past = System.monotonic_time(:millisecond) - 1
      true = :ets.update_element(ApiKeyCache.table_name(), {:gen, ak.key_hash}, {3, past})

      send(Process.whereis(ApiKeyCache), :sweep)
      _ = :sys.get_state(ApiKeyCache)

      assert :ets.lookup(ApiKeyCache.table_name(), {:gen, ak.key_hash}) == []
    end

    test "a freshly-bumped generation entry is NOT reaped (deadline refreshed on bump)" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      :ok = ApiKeyCache.invalidate(ak.key_hash)
      # Force the deadline into the past...
      past = System.monotonic_time(:millisecond) - 1
      true = :ets.update_element(ApiKeyCache.table_name(), {:gen, ak.key_hash}, {3, past})
      # ...then a fresh bump refreshes it to the future, surviving the sweep.
      :ok = ApiKeyCache.invalidate(ak.key_hash)

      send(Process.whereis(ApiKeyCache), :sweep)
      _ = :sys.get_state(ApiKeyCache)

      assert [{{:gen, _}, _gen, _reap}] =
               :ets.lookup(ApiKeyCache.table_name(), {:gen, ak.key_hash})
    end

    test "reaping a generation entry preserves the never-stale invariant" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      # A key bumped at least once: the gen entry is present at gen >= 1, so there
      # is no in-flight stamp-0 reader for it.
      :ok = ApiKeyCache.invalidate(ak.key_hash)
      gen = ApiKeyCache.generation(ak.key_hash)
      assert gen >= 1

      # Reap the (idle) gen entry -> current generation resets to the 0 default.
      past = System.monotonic_time(:millisecond) - 1
      true = :ets.update_element(ApiKeyCache.table_name(), {:gen, ak.key_hash}, {3, past})
      send(Process.whereis(ApiKeyCache), :sweep)
      _ = :sys.get_state(ApiKeyCache)
      assert ApiKeyCache.generation(ak.key_hash) == 0

      # A value stamped with the pre-reap generation (>= 1) can never equal the
      # post-reap 0 default, so a late stale repopulation is still rejected — the
      # reap does not resurrect a stale HIT.
      :ok = ApiKeyCache.put(ak.key_hash, ak, gen)
      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end
  end

  describe "tenant isolation (TC-33.3.5)" do
    test "revoking tenant A's key leaves tenant B's cached key unaffected" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      {raw_a, ak_a} = fixture(:api_key, tenant_id: a.id, role: :agent)
      {raw_b, _ak_b} = fixture(:api_key, tenant_id: b.id, role: :agent)

      # Cache both.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw_a)
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw_b)

      # Revoke ONLY A.
      {:ok, _} = Auth.revoke_api_key(ak_a)

      # A rejected, B untouched.
      assert Auth.verify_api_key(raw_a) == {:error, :unauthorized}
      assert {:ok, %ApiKey{tenant_id: tenant_b_id}} = Auth.verify_api_key(raw_b)
      assert tenant_b_id == b.id
    end
  end

  describe "tenant-row + agent-binding invalidation (AC-33.3.3/.5)" do
    test "suspending a tenant busts its cached keys (custody/status fields compose with US-33.2)" do
      tenant = fixture(:tenant)
      {raw, ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      # Cache the key WITH its :tenant preloaded (status/custody_halted_at).
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      # A tenant-row mutation leaves the cached preloaded :tenant stale, so it must
      # bust the tenant's cached keys (invalidate_tenant_key_cache).
      {:ok, _suspended} = Loopctl.Tenants.suspend_tenant(tenant)

      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end

    test "halting a tenant's custody busts its cached keys" do
      tenant = fixture(:tenant)
      {raw, ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      {:ok, _halted} = Loopctl.Tenants.halt_custody(tenant.id)

      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end

    test "binding an agent to a key busts that key's cached entry (agent_id scope change)" do
      tenant = fixture(:tenant)
      {raw, ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      {:ok, _agent} =
        Loopctl.Agents.register_agent(
          tenant.id,
          %{name: "bound-worker", agent_type: :implementer},
          api_key_id: ak.id
        )

      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end

    test "the tenant fan-out is bounded to ACTIVE keys — a revoked key_hash is not bumped" do
      tenant = fixture(:tenant)
      {active_raw, active_ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)
      {_revoked_raw, revoked_ak} = fixture(:api_key, tenant_id: tenant.id, role: :agent)

      # Cache the active key; revoke the other (revoke bumps its generation once).
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(active_raw)
      {:ok, _} = Auth.revoke_api_key(revoked_ak)
      revoked_gen_before = ApiKeyCache.generation(revoked_ak.key_hash)
      active_gen_before = ApiKeyCache.generation(active_ak.key_hash)

      # A tenant mutation fans out invalidation. With the revoked filter (finding-2),
      # only the ACTIVE key's generation advances; the revoked key — never cached, so
      # never needing a bust — is excluded, capping the fan-out under Epic 33's
      # accumulation of revoked ephemeral dispatch keys.
      {:ok, _suspended} = Loopctl.Tenants.suspend_tenant(tenant)

      assert ApiKeyCache.generation(revoked_ak.key_hash) == revoked_gen_before
      assert ApiKeyCache.generation(active_ak.key_hash) > active_gen_before
    end
  end

  describe "cross-node invalidation" do
    test "invalidate_cluster busts the local entry and bumps the generation" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      :ok = ApiKeyCache.put(ak.key_hash, ak)
      gen0 = ApiKeyCache.generation(ak.key_hash)

      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      :ok = ApiKeyCache.invalidate_cluster(ak.key_hash)

      assert ApiKeyCache.fetch(ak.key_hash) == :miss
      assert ApiKeyCache.generation(ak.key_hash) > gen0
    end

    test "a peer node's invalidation broadcast busts this node's entry" do
      {_raw, ak} = fixture(:api_key, role: :agent)
      :ok = ApiKeyCache.put(ak.key_hash, ak)
      assert {:ok, _} = ApiKeyCache.fetch(ak.key_hash)

      Phoenix.PubSub.broadcast(
        Loopctl.PubSub,
        "auth:api_key_cache:invalidate",
        {:invalidate, ak.key_hash}
      )

      _ = :sys.get_state(ApiKeyCache)

      assert ApiKeyCache.fetch(ak.key_hash) == :miss
    end
  end

  describe "table options (AC-33.3.1)" do
    test "the ETS table is a :public, :named_table, :set with read_concurrency" do
      table = ApiKeyCache.table_name()

      assert :ets.info(table, :named_table) == true
      assert :ets.info(table, :protection) == :public
      assert :ets.info(table, :type) == :set
      assert :ets.info(table, :read_concurrency) == true
    end
  end

  describe "no secrets logged (AC-33.3.7)" do
    test "neither the raw key nor the key_hash is logged on verify/revoke" do
      {raw, ak} = fixture(:api_key, role: :agent)
      key_hash = ak.key_hash

      log =
        capture_log(fn ->
          {:ok, _} = Auth.verify_api_key(raw)
          {:ok, _} = Auth.verify_api_key(raw)
          {:ok, _} = Auth.revoke_api_key(ak)
          _ = Auth.verify_api_key(raw)
        end)

      refute log =~ raw
      refute log =~ key_hash
    end
  end

  # Insert a dispatch row directly (uncast tenant_id/api_key_id) so we can exercise
  # the Dispatches.revoke/2 cascade without the full mint ceremony. `expires_at`
  # defaults to the future; pass a past value to exercise the expired-dispatch sweep.
  defp dispatch_for(tenant_id, api_key_id, expires_at \\ nil) do
    now = DateTime.utc_now()

    %Loopctl.Dispatches.Dispatch{}
    |> Ecto.Changeset.change(%{
      tenant_id: tenant_id,
      api_key_id: api_key_id,
      role: :agent,
      lineage_path: [],
      expires_at: expires_at || DateTime.add(now, 3600, :second),
      created_at: now
    })
    |> AdminRepo.insert!()
  end
end
