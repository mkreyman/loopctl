defmodule LoopctlRunner.FetchLockTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.FetchLock

  setup do
    name = :"fetch_lock_#{System.unique_integer([:positive])}"
    start_supervised!({FetchLock, name: name})
    {:ok, lock: name}
  end

  # A process that waits for the key, reports when it holds it, and releases it when told.
  defp waiter(lock, label) do
    test = self()

    spawn_link(fn ->
      :ok = FetchLock.acquire(lock, :repo, 5_000)
      send(test, {:holds, label})

      receive do
        :release -> FetchLock.release(lock, :repo)
      end
    end)
  end

  defp queued(lock), do: lock |> :sys.get_state() |> Map.get(:repo) |> elem(2) |> :queue.len()

  test "waiters get the key in the order they asked for it", %{lock: lock} do
    :ok = FetchLock.acquire(lock, :repo, 1_000)
    first = waiter(lock, :first)
    wait_for(fn -> queued(lock) == 1 end)
    second = waiter(lock, :second)
    wait_for(fn -> queued(lock) == 2 end)

    :ok = FetchLock.release(lock, :repo)
    assert_receive {:holds, :first}, 1_000
    refute_received {:holds, :second}

    send(first, :release)
    assert_receive {:holds, :second}, 1_000
    send(second, :release)
  end

  test "a holder's death hands the key on", %{lock: lock} do
    holder = spawn(fn -> FetchLock.acquire(lock, :repo, 1_000) && Process.sleep(:infinity) end)
    wait_for(fn -> match?(%{repo: _}, :sys.get_state(lock)) end)
    next = waiter(lock, :next)

    Process.exit(holder, :kill)
    assert_receive {:holds, :next}, 1_000
    send(next, :release)
  end

  test "a waiter that gives up leaves the queue, and the key goes on past it", %{lock: lock} do
    :ok = FetchLock.acquire(lock, :repo, 1_000)
    gave_up = Task.async(fn -> FetchLock.acquire(lock, :repo, 50) end)
    assert Task.await(gave_up) == :timeout
    assert queued(lock) == 0

    :ok = FetchLock.release(lock, :repo)
    assert :sys.get_state(lock) == %{}
  end

  defp wait_for(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_for(check, tries - 1)
    end
  end
end
