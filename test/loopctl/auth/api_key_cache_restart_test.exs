defmodule Loopctl.Auth.ApiKeyCacheRestartTest do
  # async: false ON PURPOSE. These tests mutate NODE-GLOBAL supervised state — they
  # delete the single shared `:named_table` — so no concurrent async test may
  # observe the momentarily-absent table. Keep them OUT of the async
  # `ApiKeyCacheTest` module.
  #
  # NOTE on why we do NOT stop the supervised owner (unlike a naive mirror of
  # `settings_cache_restart_test.exs`): `Loopctl.Auth.ApiKeyCache` and
  # `Loopctl.Llm.SettingsCache` are BOTH `:one_for_one` children of the same root
  # `Loopctl.Supervisor`. A `GenServer.stop` of either triggers a supervised
  # restart that counts against the root supervisor's shared restart-intensity
  # window. The SettingsCache restart test already spends restarts in that window;
  # adding more here can exceed `max_restarts` and take the whole app (Repo,
  # Endpoint, sandbox owners) down mid-run. So we reproduce the SAME observable
  # failure mode — "table destroyed -> recreated EMPTY -> repopulates
  # read-through", plus the rescue clauses that keep fetch/put/invalidate/
  # generation safe while the table is momentarily absent — by deleting the ETS
  # table and handing a fresh empty one back to the live owner via
  # `:ets.give_away/3` (exactly the empty table `init/1` would create), with zero
  # root-supervisor restart cost.

  use Loopctl.DataCase, async: false

  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache

  describe "cold start / table-missing resilience (AC-33.3.7)" do
    test "with the ETS table absent, fetch/put/invalidate/generation are safe (rescue clauses)" do
      {_raw, ak} = fixture(:api_key, role: :agent)

      # Destroy the table out from under the owner, simulating the window after a
      # crash and before init/1 has recreated it.
      true = :ets.delete(ApiKeyCache.table_name())
      assert :ets.whereis(ApiKeyCache.table_name()) == :undefined

      # Every direct ETS op must rescue "table does not exist" to a safe default so
      # an auth request never crashes mid-restart.
      assert ApiKeyCache.fetch(ak.key_hash) == :miss
      assert ApiKeyCache.generation(ak.key_hash) == 0
      assert ApiKeyCache.put(ak.key_hash, ak, 0) == :ok
      assert ApiKeyCache.put(ak.key_hash, ak) == :ok
      assert ApiKeyCache.invalidate(ak.key_hash) == :ok

      restore_empty_table!()

      # The recreated EMPTY table repopulates read-through with correct auth material.
      {raw2, ak2} = fixture(:api_key, role: :agent)
      assert ApiKeyCache.fetch(ak2.key_hash) == :miss
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw2)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak2.key_hash)
    end

    test "an emptied table repopulates read-through and persists no secrets" do
      {raw, ak} = fixture(:api_key, role: :agent)

      # Warm the cache.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash)

      # Cold start: destroy the table and hand back a fresh EMPTY one (what init/1
      # would create on a supervised restart) — nothing is persisted (AC-33.3.7).
      true = :ets.delete(ApiKeyCache.table_name())
      restore_empty_table!()

      # The previously-cached key is now a miss (empty table)...
      assert ApiKeyCache.fetch(ak.key_hash) == :miss

      # ...and a verify repopulates read-through from the DB.
      assert {:ok, %ApiKey{}} = Auth.verify_api_key(raw)
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(ak.key_hash)
    end
  end

  # Recreate the shared named table exactly as `init/1` does and transfer ownership
  # to the live supervised owner, so the table survives this test process and no
  # supervised restart (root restart-intensity cost) is incurred. The owner's
  # `handle_info/2` catch-all swallows the `{'ETS-TRANSFER', ...}` message.
  defp restore_empty_table! do
    owner = Process.whereis(ApiKeyCache)

    table =
      :ets.new(ApiKeyCache.table_name(), [:set, :public, :named_table, read_concurrency: true])

    true = :ets.give_away(table, owner, :restored)
    :ok
  end
end
