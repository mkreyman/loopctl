defmodule Loopctl.Auth.ApiKeyCacheRestartTest do
  # The restart path (AC-33.3.7) runs on an instance of this test's OWN: a
  # `Loopctl.Auth.ApiKeyCache` started under the test supervisor with its own `:name` and
  # `:table`. Stopping it destroys THAT table and the test supervisor restarts it, so the
  # real "owner died -> table destroyed -> recreated EMPTY" path is exercised without ever
  # touching the app's owner (whose table every authenticated request reads), its table, or
  # the root supervisor's restart-intensity window.
  #
  # The read-through is driven by hand against this instance's table — capture the
  # generation, resolve the key, `put/4` under that generation — because the auth boundary
  # (`Loopctl.Auth.verify_api_key/1`) only ever reads the app's table, and the caller's key
  # is not something a test injects into it.
  use Loopctl.DataCase, async: true

  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache

  setup do
    unique = System.unique_integer([:positive])
    name = :"api_key_cache_restart_#{unique}"
    table = :"api_key_cache_restart_table_#{unique}"

    start_supervised!({ApiKeyCache, name: name, table: table})

    {:ok, name: name, table: table}
  end

  describe "cold start / table-missing resilience (AC-33.3.7)" do
    test "with the ETS table absent, fetch/put/invalidate/generation are safe (rescue clauses)",
         %{name: name, table: table} do
      {_raw, ak} = fixture(:api_key, role: :agent)

      # Destroy the table out from under the owner, simulating the window after a
      # crash and before init/1 has recreated it.
      true = :ets.delete(table)
      assert :ets.whereis(table) == :undefined

      # Every direct ETS op must rescue "table does not exist" to a safe default so an
      # auth request never crashes mid-restart.
      assert ApiKeyCache.fetch(ak.key_hash, table) == :miss
      assert ApiKeyCache.generation(ak.key_hash, table) == 0
      assert ApiKeyCache.put(ak.key_hash, ak, 0, table) == :ok
      assert ApiKeyCache.invalidate(ak.key_hash, table) == :ok

      restart_owner!(name, table)

      # The recreated EMPTY table repopulates read-through with correct auth material.
      {raw2, ak2} = fixture(:api_key, role: :agent)
      await_invalidation_broadcast!(name)
      assert ApiKeyCache.fetch(ak2.key_hash, table) == :miss
      assert {:ok, %ApiKey{}} = read_through(raw2, ak2.key_hash, table)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak2.key_hash, table)
    end

    test "a restart empties the table, which repopulates read-through and persists no secrets",
         %{name: name, table: table} do
      {raw, ak} = fixture(:api_key, role: :agent)
      await_invalidation_broadcast!(name)

      # Warm this instance's cache.
      assert {:ok, %ApiKey{}} = read_through(raw, ak.key_hash, table)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash, table)

      # Cold start: the owner dies, its table goes with it, and init/1 recreates it EMPTY —
      # nothing is persisted (AC-33.3.7).
      restart_owner!(name, table)

      # The previously-cached key is now a miss (empty table)...
      assert ApiKeyCache.fetch(ak.key_hash, table) == :miss

      # ...and a read-through repopulates it from the DB.
      assert {:ok, %ApiKey{}} = read_through(raw, ak.key_hash, table)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash, table)
    end
  end

  # Creating a key invalidates its key_hash cluster-wide: the app's owner broadcasts, and
  # this instance subscribes to the same topic, so it bumps the generation in ITS table too
  # — asynchronously. Wait for both hops before populating, or that bump lands after the
  # put and the entry reads as stale (which is the bridge working, not a failure).
  defp await_invalidation_broadcast!(name) do
    _ = :sys.get_state(ApiKeyCache)
    _ = :sys.get_state(name)
    :ok
  end

  # A miss's read-through against this instance's table: the generation is captured BEFORE
  # the key is resolved, exactly as `Auth.verify_api_key/1` does on the app's table.
  defp read_through(raw, key_hash, table) do
    generation = ApiKeyCache.generation(key_hash, table)

    with {:ok, %ApiKey{} = api_key} <- Auth.verify_api_key(raw) do
      :ok = ApiKeyCache.put(key_hash, api_key, generation, table)
      {:ok, api_key}
    end
  end

  # Stop this test's owner and wait for the test supervisor to restart it (a :permanent
  # child) and for init/1 to recreate its table.
  defp restart_owner!(name, table) do
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    :ok = GenServer.stop(name, :normal)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> flunk("ApiKeyCache owner did not stop")
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
