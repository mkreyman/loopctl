defmodule Loopctl.Llm.SettingsCacheRestartTest do
  # The restart path (AC-32.3.5) runs on an instance of this test's OWN: a
  # `Loopctl.Llm.SettingsCache` started under the test supervisor with its own `:name` and
  # `:table`. Stopping it destroys THAT table and the test supervisor restarts it, so the
  # real "owner died -> table destroyed -> recreated empty" path is exercised without ever
  # touching the app's owner, its table, or the root supervisor's restart-intensity window.
  use Loopctl.DataCase, async: true

  alias Loopctl.Llm
  alias Loopctl.Llm.SettingsCache
  alias Loopctl.Llm.TenantLlmSettings

  setup do
    unique = System.unique_integer([:positive])
    name = :"settings_cache_restart_#{unique}"
    table = :"settings_cache_restart_table_#{unique}"

    start_supervised!({SettingsCache, name: name, table: table})

    {:ok, name: name, table: table}
  end

  describe "restart / table-missing resilience (AC-32.3.5)" do
    test "with the ETS table absent, fetch/put/invalidate/generation are safe (rescue clauses)",
         %{name: name, table: table} do
      tenant = fixture(:tenant)

      # Destroy the table out from under the owner, simulating the window after the
      # owner has died and before init/1 has recreated it.
      true = :ets.delete(table)
      assert :ets.whereis(table) == :undefined

      # Every direct ETS op must rescue "table does not exist" to a safe default so a
      # provider call never crashes mid-restart.
      assert SettingsCache.fetch(tenant.id, table) == :miss
      assert SettingsCache.generation(tenant.id, table) == 0

      assert SettingsCache.put(tenant.id, %TenantLlmSettings{tenant_id: tenant.id}, 0, table) ==
               :ok

      assert SettingsCache.invalidate(tenant.id, table) == :ok

      # `put/2` (stamp with the current generation) is `generation/2` then `put/4`, both just
      # shown safe; composed here against this instance's absent table. And the production
      # read-through still answers mid-restart (a tenant with no row reads `nil`).
      assert SettingsCache.put(tenant.id, nil, SettingsCache.generation(tenant.id, table), table) ==
               :ok

      assert Llm.get_settings(tenant.id, table) == nil

      # Restore the table by restarting its supervised owner (init recreates it).
      restart_owner!(name, table)

      # The recreated table repopulates read-through with fresh, correct credentials.
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-after-recreate"})
      await_invalidation_broadcast!(name)
      assert %TenantLlmSettings{api_key: "sk-after-recreate"} = repopulate!(tenant.id, table)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id, table)
    end

    test "a GenServer restart yields an empty table that repopulates read-through",
         %{name: name, table: table} do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-survives-restart"})
      await_invalidation_broadcast!(name)

      # Warm this instance's cache.
      assert %TenantLlmSettings{} = repopulate!(tenant.id, table)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id, table)

      # Restart the owner: its ETS table is destroyed and init/1 recreates an EMPTY one
      # (nothing is persisted — AC-32.3.5).
      restart_owner!(name, table)

      # The previously-cached tenant is now a miss (empty table)...
      assert SettingsCache.fetch(tenant.id, table) == :miss

      # ...and a read repopulates read-through from the DB with the same decrypted key.
      assert %TenantLlmSettings{api_key: "sk-survives-restart"} = repopulate!(tenant.id, table)
      assert {:ok, %TenantLlmSettings{}} = SettingsCache.fetch(tenant.id, table)
    end
  end

  # `upsert_settings/2` invalidates cluster-wide: the app's owner broadcasts, and this
  # instance subscribes to the same topic, so it bumps the tenant's generation in ITS table
  # too — asynchronously. Wait for both hops before populating, or that bump lands after
  # the put and the entry reads as stale (which is the bridge working, not a failure).
  defp await_invalidation_broadcast!(name) do
    _ = :sys.get_state(SettingsCache)
    _ = :sys.get_state(name)
    :ok
  end

  # The real read-through (`Llm.get_settings/2`) against this instance's table.
  defp repopulate!(tenant_id, table), do: Llm.get_settings(tenant_id, table)

  # Stop this test's owner and wait for the test supervisor to restart it (a :permanent
  # child) and for init/1 to recreate its table.
  defp restart_owner!(name, table) do
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    :ok = GenServer.stop(name, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> flunk("SettingsCache owner did not stop")
    end

    wait_until(fn ->
      new_pid = Process.whereis(name)
      is_pid(new_pid) and new_pid != pid and :ets.whereis(table) != :undefined
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
