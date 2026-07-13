defmodule Loopctl.Llm.SettingsCacheTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Llm
  alias Loopctl.Llm.SettingsCache
  alias Loopctl.Llm.TenantLlmSettings

  import Ecto.Query
  import ExUnit.CaptureLog

  # The ETS owner runs as part of the app supervision tree in the test env, so the
  # table already exists — no start_supervised needed (mirrors EmbeddingCircuitBreaker
  # tests). async: true is safe because every test uses fresh tenant fixtures = unique
  # tenant_id keys, so the shared named table is never contended across tests.

  describe "fetch/2 + put/2 + invalidate/1 (ETS unit)" do
    test "fetch on an unknown tenant is a miss" do
      tenant = fixture(:tenant)
      assert SettingsCache.fetch(tenant.id) == :miss
    end

    test "put then fetch returns the stored struct as a hit" do
      tenant = fixture(:tenant)
      settings = fixture(:tenant_llm_settings, tenant_id: tenant.id, api_key: "sk-cache-unit")

      :ok = SettingsCache.put(tenant.id, settings)

      assert {:ok, %TenantLlmSettings{} = cached} = SettingsCache.fetch(tenant.id)
      assert cached.id == settings.id
    end

    test "negative caching: a stored nil is a HIT (distinct from a miss)" do
      tenant = fixture(:tenant)

      :ok = SettingsCache.put(tenant.id, nil)

      assert SettingsCache.fetch(tenant.id) == {:ok, nil}
    end

    test "invalidate deletes the entry (back to a miss)" do
      tenant = fixture(:tenant)
      settings = fixture(:tenant_llm_settings, tenant_id: tenant.id, api_key: "sk-inv")

      :ok = SettingsCache.put(tenant.id, settings)
      assert {:ok, _} = SettingsCache.fetch(tenant.id)

      :ok = SettingsCache.invalidate(tenant.id)
      assert SettingsCache.fetch(tenant.id) == :miss
    end

    test "invalidate BUMPS the tenant's generation (monotonic authority)" do
      tenant = fixture(:tenant)
      gen0 = SettingsCache.generation(tenant.id)

      :ok = SettingsCache.invalidate(tenant.id)
      gen1 = SettingsCache.generation(tenant.id)
      assert gen1 > gen0

      :ok = SettingsCache.invalidate(tenant.id)
      assert SettingsCache.generation(tenant.id) > gen1
    end

    test "a put stamped with a generation older than the current one is a MISS (stale repopulation rejected)" do
      tenant = fixture(:tenant)
      settings = fixture(:tenant_llm_settings, tenant_id: tenant.id, api_key: "sk-stale-stamp")

      # Capture a generation, then an invalidation bumps it past that capture.
      stale_gen = SettingsCache.generation(tenant.id)
      :ok = SettingsCache.invalidate(tenant.id)
      assert SettingsCache.generation(tenant.id) > stale_gen

      # A LATE read-through repopulation stamped with the pre-invalidation generation
      # (the classic race: reader snapshotted before the writer's invalidate) is
      # inserted but must NEVER be trusted — fetch rejects it as stale.
      :ok = SettingsCache.put(tenant.id, settings, stale_gen)
      assert SettingsCache.fetch(tenant.id) == :miss

      # A put stamped with the CURRENT generation IS served (fresh repopulation).
      :ok = SettingsCache.put(tenant.id, settings, SettingsCache.generation(tenant.id))
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id)
    end

    test "reset/1 is an alias for invalidate/1" do
      tenant = fixture(:tenant)
      :ok = SettingsCache.put(tenant.id, nil)
      assert {:ok, nil} = SettingsCache.fetch(tenant.id)

      :ok = SettingsCache.reset(tenant.id)
      assert SettingsCache.fetch(tenant.id) == :miss
    end
  end

  describe "get_settings/1 read-through cache" do
    # TC-32.3.1
    test "second get is served from ETS: a direct DB mutation is NOT seen until invalidation" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-readthrough-1234",
          "extraction_model" => "model-original"
        })

      # First read populates the cache read-through.
      assert %TenantLlmSettings{extraction_model: "model-original"} = Llm.get_settings(tenant.id)

      # Mutate the row DIRECTLY in the DB (bypassing the write path / cache bust).
      {1, _} =
        from(s in TenantLlmSettings, where: s.tenant_id == ^tenant.id)
        |> AdminRepo.update_all(set: [extraction_model: "model-mutated-directly"])

      # Still the cached value — proves the 2nd read hit ETS, not the DB.
      assert %TenantLlmSettings{extraction_model: "model-original"} = Llm.get_settings(tenant.id)

      # After invalidation the next read repopulates from the DB and sees the mutation.
      :ok = SettingsCache.invalidate(tenant.id)

      assert %TenantLlmSettings{extraction_model: "model-mutated-directly"} =
               Llm.get_settings(tenant.id)
    end

    test "negative cache: nil for a tenant with no row is served read-through, busted on upsert" do
      tenant = fixture(:tenant)

      # No row yet -> nil, cached negatively.
      assert Llm.get_settings(tenant.id) == nil
      assert SettingsCache.fetch(tenant.id) == {:ok, nil}

      # The sole creation path invalidates the nil entry.
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-created-now"})

      assert %TenantLlmSettings{} = Llm.get_settings(tenant.id)
      assert {:ok, %{api_key: "sk-created-now"}} = Llm.resolve(tenant.id, :extraction)
    end
  end

  describe "upsert_settings/2 cache invalidation (TC-32.3.2)" do
    test "rotate-then-read returns the NEW settings, never stale" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-old-key-aaaa",
          "extraction_model" => "model-old"
        })

      # Cache it.
      assert {:ok, %{api_key: "sk-old-key-aaaa", model: "model-old"}} =
               Llm.resolve(tenant.id, :extraction)

      # Rotate via the write path.
      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-new-key-bbbb",
          "extraction_model" => "model-new"
        })

      # Next read reflects the rotation — not the stale cached credentials.
      assert %TenantLlmSettings{extraction_model: "model-new"} = Llm.get_settings(tenant.id)

      assert {:ok, %{api_key: "sk-new-key-bbbb", model: "model-new"}} =
               Llm.resolve(tenant.id, :extraction)
    end
  end

  describe "read-through repopulation race — never serve stale (AC-32.3.3)" do
    test "a rotation that commits during a slow reader's DB load is NEVER masked by the reader's stale repopulation" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-original-key"})

      # Reader R begins a read-through: it captures the cache generation BEFORE its
      # (here, simulated-slow) DB load — exactly as Llm.get_settings/1 does.
      captured_generation = SettingsCache.generation(tenant.id)

      # Meanwhile a key rotation commits AND invalidates the cache (bumping the
      # generation). R's in-flight SELECT snapshotted the OLD row.
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-rotated-key"})

      # R finally repopulates with the stale struct it snapshotted, stamped with the
      # generation it captured before the rotation.
      stale = %TenantLlmSettings{tenant_id: tenant.id, api_key: "sk-original-key"}
      :ok = SettingsCache.put(tenant.id, stale, captured_generation)

      # The stale repopulation must NOT be served — the entry's stamp is behind the
      # post-rotation generation, so fetch rejects it.
      assert SettingsCache.fetch(tenant.id) == :miss

      # And the next resolve reloads the ROTATED credentials read-through — never the
      # revoked original key (the invariant AC-32.3.3 protects: never serve stale).
      assert {:ok, %{api_key: "sk-rotated-key"}} = Llm.resolve(tenant.id, :extraction)
    end
  end

  describe "tenant isolation (AC-32.3.4 / TC-32.3.3)" do
    test "two tenants both cached; rotating A leaves B unchanged and A returns rotated" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      {:ok, _} = Llm.upsert_settings(a.id, %{"api_key" => "sk-A-original"})
      {:ok, _} = Llm.upsert_settings(b.id, %{"api_key" => "sk-B-original"})

      # Cache both.
      assert {:ok, %{api_key: "sk-A-original"}} = Llm.resolve(a.id, :extraction)
      assert {:ok, %{api_key: "sk-B-original"}} = Llm.resolve(b.id, :extraction)

      # Rotate ONLY A.
      {:ok, _} = Llm.upsert_settings(a.id, %{"api_key" => "sk-A-rotated"})

      # A reflects the rotation; B's cached entry is untouched.
      assert {:ok, %{api_key: "sk-A-rotated"}} = Llm.resolve(a.id, :extraction)
      assert {:ok, %{api_key: "sk-B-original"}} = Llm.resolve(b.id, :extraction)
    end

    test "A's cache entry is never returned for B (keys are tenant_id-scoped)" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      settings_a = fixture(:tenant_llm_settings, tenant_id: a.id, api_key: "sk-A")
      :ok = SettingsCache.put(a.id, settings_a)

      # B has nothing cached and no row -> nil, never A's struct.
      assert SettingsCache.fetch(b.id) == :miss
      assert Llm.get_settings(b.id) == nil
    end
  end

  describe "secret safety + cold start (AC-32.3.5)" do
    test "a reset yields an empty entry that repopulates read-through" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-cold-start"})

      assert %TenantLlmSettings{} = Llm.get_settings(tenant.id)
      assert {:ok, _} = SettingsCache.fetch(tenant.id)

      # Simulate a cold start for this tenant: empty entry.
      :ok = SettingsCache.reset(tenant.id)
      assert SettingsCache.fetch(tenant.id) == :miss

      # Repopulates read-through with the same decrypted key.
      assert {:ok, %{api_key: "sk-cold-start"}} = Llm.resolve(tenant.id, :extraction)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id)
    end

    test "the decrypted key is never logged on a get or a rotate" do
      tenant = fixture(:tenant)
      secret = "sk-should-never-appear-in-logs-9999"

      log =
        capture_log(fn ->
          {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => secret})
          _ = Llm.get_settings(tenant.id)
          {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => secret <> "-rotated"})
          _ = Llm.get_settings(tenant.id)
        end)

      refute log =~ secret
      refute log =~ "sk-should-never-appear-in-logs-9999-rotated"
    end
  end

  describe "table options (AC-32.3.1)" do
    test "the ETS table is a :public, :named_table, :set with read_concurrency" do
      table = SettingsCache.table_name()

      assert :ets.info(table, :named_table) == true
      assert :ets.info(table, :protection) == :public
      assert :ets.info(table, :type) == :set
      assert :ets.info(table, :read_concurrency) == true
    end
  end

  # AC-32.3.5: a GenServer restart yields an EMPTY table that repopulates read-through.
  # These exercise the ACTUAL restart failure mode — the owner dying destroys the whole
  # named ETS table and init/1 recreates it — plus the rescue clauses that keep fetch/
  # put/invalidate safe while the table is momentarily absent mid-restart. They restart
  # the supervised owner; concurrent read-through consumers self-heal (a transient miss
  # just reloads from the DB), and same-module tests never run concurrently, so nuking
  # the shared table here is safe.
  describe "restart / table-missing resilience (AC-32.3.5)" do
    test "with the ETS table absent, fetch/put/invalidate/generation are safe (rescue clauses)" do
      tenant = fixture(:tenant)

      # Destroy the table out from under the owner, simulating the window after the
      # owner has died and before init/1 has recreated it.
      true = :ets.delete(SettingsCache.table_name())
      assert :ets.whereis(SettingsCache.table_name()) == :undefined

      # Every direct ETS op must rescue "table does not exist" to a safe default so a
      # provider call never crashes mid-restart.
      assert SettingsCache.fetch(tenant.id) == :miss
      assert SettingsCache.generation(tenant.id) == 0
      assert SettingsCache.put(tenant.id, %TenantLlmSettings{tenant_id: tenant.id}, 0) == :ok
      assert SettingsCache.put(tenant.id, nil) == :ok
      assert SettingsCache.invalidate(tenant.id) == :ok

      # Restore the shared table by restarting its supervised owner (init recreates it).
      restart_settings_cache!()

      # The recreated table repopulates read-through with fresh, correct credentials.
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-after-recreate"})
      assert {:ok, %{api_key: "sk-after-recreate"}} = Llm.resolve(tenant.id, :extraction)
    end

    test "a GenServer restart yields an empty table that repopulates read-through" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-survives-restart"})

      # Warm the cache.
      assert %TenantLlmSettings{} = Llm.get_settings(tenant.id)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id)

      # Restart the owner: its ETS table is destroyed and init/1 recreates an EMPTY one
      # (nothing is persisted — AC-32.3.5).
      restart_settings_cache!()

      # The previously-cached tenant is now a miss (empty table)...
      assert SettingsCache.fetch(tenant.id) == :miss

      # ...and a read repopulates read-through from the DB with the same decrypted key.
      assert {:ok, %{api_key: "sk-survives-restart"}} = Llm.resolve(tenant.id, :extraction)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id)
    end
  end

  # Stop the supervised SettingsCache owner and wait for the app supervisor to restart
  # it (a :permanent child) and for init/1 to recreate the named table. This reproduces
  # the real "owner died -> table destroyed -> recreated empty" restart path.
  defp restart_settings_cache! do
    pid = Process.whereis(SettingsCache)
    ref = Process.monitor(pid)
    :ok = GenServer.stop(SettingsCache, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> flunk("SettingsCache owner did not stop")
    end

    wait_until(fn ->
      is_pid(Process.whereis(SettingsCache)) and
        :ets.whereis(SettingsCache.table_name()) != :undefined
    end)
  end

  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met within the retry window")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
