defmodule Loopctl.Knowledge.EmbeddingConcurrencyDownTest do
  @moduledoc """
  US-37.2 (AC-37.2.3 / AC-37.2.5): the concurrency gate FAILS SAFE when its GenServer
  is down.

  `run_embedding_task/3` calls `acquire/1` OUTSIDE the supervised embedding task, so
  no `async_nolink` isolates it — if the `EmbeddingConcurrency` GenServer is down or
  mid-restart (a restart storm during exactly the burst this gate defends against, or
  app shutdown), an UNGUARDED `GenServer.call` would raise `:exit` and 500 the
  interactive search. Both `acquire/3` and `release/1` therefore catch the exit:
  `acquire` degrades to `{:error, :rate_limited_local}` (→ keyword fallback, never a
  500), and `release` no-ops with `:ok` (a dead GenServer is itself a counter reset,
  so nothing leaks).

  Each test starts a gate of its OWN under a unique name, stops it, and calls that name
  (`acquire/4`, `release/2`) — the app's gate, which every other test's embeddings go
  through, is never taken down.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.EmbeddingConcurrency, as: EC

  setup do
    # A gate of this test's own, then DOWN: its registered name is free again, so a call
    # to it exits with :noproc exactly as a call to a terminated app gate would.
    name = :"embedding_concurrency_down_#{System.unique_integer([:positive])}"
    start_supervised!({EC, name: name})
    :ok = stop_supervised(EC)
    refute Process.whereis(name)

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
end
