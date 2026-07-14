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

  This is `async: false` and terminates the SINGLETON app-supervised GenServer via the
  supervisor (so it is NOT auto-restarted until we restart it), then restores it in an
  `on_exit` — exclusive execution guarantees no concurrent test observes the gate down.
  """
  use ExUnit.Case, async: false

  alias Loopctl.Knowledge.EmbeddingConcurrency, as: EC

  @sup Loopctl.Supervisor

  setup do
    # Terminate the singleton gate WITHOUT auto-restart; guarantee restoration.
    :ok = Supervisor.terminate_child(@sup, EC)

    on_exit(fn ->
      # restart_child returns {:ok, pid} (or {:error, :running} if a prior restore
      # already brought it back) — either way the gate is up again for later tests.
      case Supervisor.restart_child(@sup, EC) do
        {:ok, _pid} -> :ok
        {:error, :running} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    :ok
  end

  test "acquire/1 fails safe to {:error, :rate_limited_local} when the gate is down" do
    tenant_id = Ecto.UUID.generate()
    # The registered name is unregistered while the child is terminated, so the
    # GenServer.call inside acquire/3 exits with :noproc — the catch converts it.
    assert {:error, :rate_limited_local} = EC.acquire(tenant_id)
    assert {:error, :rate_limited_local} = EC.acquire(tenant_id, 10, 5)
  end

  test "release/1 no-ops to :ok when the gate is down" do
    tenant_id = Ecto.UUID.generate()
    assert :ok = EC.release(tenant_id)
  end
end
