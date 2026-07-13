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
end
