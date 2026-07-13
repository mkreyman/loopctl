defmodule Loopctl.Auth.ApiKeyCacheTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache

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
  # the Dispatches.revoke/2 cascade without the full mint ceremony.
  defp dispatch_for(tenant_id, api_key_id) do
    now = DateTime.utc_now()

    %Loopctl.Dispatches.Dispatch{}
    |> Ecto.Changeset.change(%{
      tenant_id: tenant_id,
      api_key_id: api_key_id,
      role: :agent,
      lineage_path: [],
      expires_at: DateTime.add(now, 3600, :second),
      created_at: now
    })
    |> AdminRepo.insert!()
  end
end
