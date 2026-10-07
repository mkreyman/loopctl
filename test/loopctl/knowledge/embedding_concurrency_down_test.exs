defmodule Loopctl.Knowledge.EmbeddingConcurrencyDownTest do
  @moduledoc """
  US-37.2 (AC-37.2.3 / AC-37.2.5): the concurrency gate FAILS SAFE when its GenServer
  is down.

  `run_embedding_task/6` calls `acquire/1` OUTSIDE the supervised embedding task, so
  no `async_nolink` isolates it — if the `EmbeddingConcurrency` GenServer is down or
  mid-restart (a restart storm during exactly the burst this gate defends against, or
  app shutdown), an UNGUARDED `GenServer.call` would raise `:exit` and 500 the
  interactive search. Both `acquire/3` and `release/1` therefore catch the exit:
  `acquire` degrades to `{:error, :rate_limited_local}` (→ keyword fallback, never a
  500), and `release` no-ops with `:ok` (a dead GenServer is itself a counter reset,
  so nothing leaks).

  Each test starts a gate of its OWN — a unique `:name` and its own `:table` — stops it,
  and calls that name (`acquire/4`, `release/2`); the app's gate, which every other test's
  embeddings go through, is never taken down. The production entry points `acquire/1` and
  `release/1` are pinned to route through those same guarded clauses with the app's gate
  as the server, so the fail-safe proven on a down gate is the one they run.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.EmbeddingConcurrency, as: EC

  setup do
    # A gate of this test's own, then DOWN: its registered name is free again, so a call
    # to it exits with :noproc exactly as a call to a terminated app gate would.
    unique = System.unique_integer([:positive])
    name = :"embedding_concurrency_down_#{unique}"
    table = :"embedding_concurrency_down_table_#{unique}"
    pid = start_supervised!({EC, name: name, table: table})

    # Its OWN table, owned by it — never the app's, so its counters and its death touch
    # nothing another test's embeddings count against.
    assert :ets.info(table, :owner) == pid
    refute table == EC.table_name()

    # A slot taken and given back on it is counted in its table alone.
    tenant_id = Ecto.UUID.generate()
    assert :ok = EC.acquire(tenant_id, 10, 5, name)
    assert EC.tenant_count(tenant_id, table) == 1
    assert EC.tenant_count(tenant_id) == 0
    assert :ok = EC.release(tenant_id, name)
    assert EC.tenant_count(tenant_id, table) == 0

    :ok = stop_supervised(EC)
    refute Process.whereis(name)
    assert :ets.whereis(table) == :undefined
    assert :ets.whereis(EC.table_name()) != :undefined

    {:ok, gate: name}
  end

  test "acquire fails safe to {:error, :rate_limited_local} when the gate is down", %{
    gate: gate
  } do
    tenant_id = Ecto.UUID.generate()
    # The gate's name is unregistered while it is down, so the GenServer.call inside
    # acquire/4 exits with :noproc — the catch converts it.
    assert {:error, :rate_limited_local} = EC.acquire(tenant_id, 10, 5, gate)
  end

  test "release no-ops to :ok when the gate is down", %{gate: gate} do
    tenant_id = Ecto.UUID.generate()
    assert :ok = EC.release(tenant_id, gate)
  end

  describe "the production entry points route through the guarded clauses" do
    # `acquire/1` and `release/1` are what `Knowledge.run_embedding_task/6` calls. Taking the
    # app's gate down to test them would take every concurrent test's embeddings down with
    # it, so instead pin that each one IS the guarded clause above, called with the app's
    # gate: a `GenServer.call` of its own, outside that clause's `catch`, would exit into the
    # caller on a down gate — and would not appear in this trace.
    test "acquire/1 is acquire/4 with the app's gate; release/1 is release/2 with it" do
      tenant_id = Ecto.UUID.generate()

      calls =
        Loopctl.CallTrace.calls([{EC, :acquire, 4}, {EC, :release, 2}], fn ->
          assert :ok = EC.acquire(tenant_id)
          assert :ok = EC.release(tenant_id)
        end)

      assert [
               {EC, :acquire, [^tenant_id, _global, _tenant, EC]},
               {EC, :release, [^tenant_id, EC]}
             ] =
               calls
    end
  end
end
