defmodule Loopctl.Llm.SettingsCacheRestartTest do
  # async: false ON PURPOSE. These tests mutate NODE-GLOBAL supervised state — they
  # delete the single shared `:named_table` and stop the app-supervised
  # `Loopctl.Llm.SettingsCache` owner (a `:permanent` child of `Loopctl.Supervisor`)
  # to exercise the real "owner died -> table destroyed -> recreated empty" restart
  # path (AC-32.3.5). Running them serially (never concurrently with any async test)
  # means (a) no concurrent test observes the momentarily-absent table, and (b) the
  # 2 deliberate restarts here can't combine with another module's restart inside
  # the root supervisor's shared restart-intensity window. Keep them OUT of the
  # async `SettingsCacheTest` module.
  use Loopctl.DataCase, async: false

  alias Loopctl.Llm
  alias Loopctl.Llm.SettingsCache
  alias Loopctl.Llm.TenantLlmSettings

  # AC-32.3.5: a GenServer restart yields an EMPTY table that repopulates read-through.
  # These exercise the ACTUAL restart failure mode — the owner dying destroys the whole
  # named ETS table and init/1 recreates it — plus the rescue clauses that keep fetch/
  # put/invalidate safe while the table is momentarily absent mid-restart.
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
