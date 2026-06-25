defmodule Loopctl.Knowledge.ExportConcurrencyTest do
  @moduledoc """
  US-27.16 (AC-27.16.6): the streaming-export concurrency cap.

  These tests don't touch the DB (the counter is pure ETS), so they're fully
  async-safe. They use distinct, random tenant ids per test so the shared ETS
  counters never collide across concurrent tests.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ExportConcurrency, as: EC

  defp tid, do: Ecto.UUID.generate()

  describe "acquire/1 + release/1" do
    test "allows up to the per-tenant cap, then refuses" do
      # Default per-tenant cap is 1 (config). The first acquire on a tenant
      # succeeds; a second concurrent one (from another process) is refused.
      t = tid()
      assert :ok = EC.acquire(t)
      assert EC.tenant_count(t) == 1

      # A second acquirer for the SAME tenant, from another process, is over the
      # per-tenant cap of 1.
      assert {:error, :too_many_exports} = from_other_process(fn -> EC.acquire(t) end)

      assert :ok = EC.release(t)
      assert EC.tenant_count(t) == 0
    end

    test "release/1 frees the slot so a later acquire succeeds" do
      t = tid()
      assert :ok = EC.acquire(t)
      assert :ok = EC.release(t)
      # After release, another process can acquire again.
      assert :ok = from_other_process(fn -> EC.acquire(t) end)
      from_other_process(fn -> EC.release(t) end)
    end

    test "global cap bounds total in-flight exports across tenants" do
      # Global cap default is 2. Hold the global cap with two DIFFERENT tenants
      # (each within its per-tenant cap of 1), then a third tenant is refused on
      # the GLOBAL cap even though its per-tenant count is 0.
      base = EC.global_count()

      t1 = tid()
      t2 = tid()
      t3 = tid()

      # Run each acquire in its own (kept-alive) process so per-process monitoring
      # and the global counter reflect concurrent holders.
      {p1, :ok} = acquire_in_held_process(t1)
      {p2, :ok} = acquire_in_held_process(t2)

      assert EC.global_count() >= base + 2

      # Third tenant: per-tenant count 0 but global cap met → refused.
      assert {:error, :too_many_exports} = from_other_process(fn -> EC.acquire(t3) end)
      assert EC.tenant_count(t3) == 0

      release_held_process(p1, t1)
      release_held_process(p2, t2)
    end

    test "a refused acquire leaves NO counter incremented (no partial reservation)" do
      t = tid()
      assert :ok = EC.acquire(t)
      g_before = EC.global_count()

      assert {:error, :too_many_exports} = from_other_process(fn -> EC.acquire(t) end)

      # The refused (per-tenant) acquire must have undone its global increment too.
      assert EC.global_count() == g_before
      assert EC.tenant_count(t) == 1

      EC.release(t)
    end

    @tag :capture_log
    test "a crashed acquirer's slot is reclaimed by the monitor (no permanent leak)" do
      t = tid()

      # Acquire in a process that then dies WITHOUT releasing.
      {:ok, pid} =
        Task.start(fn ->
          :ok = EC.acquire(t)
          # Signal acquired, then block until killed.
          receive do
            :stop -> :ok
          end
        end)

      # Wait until the acquire is visible.
      wait_until(fn -> EC.tenant_count(t) == 1 end)
      assert EC.tenant_count(t) == 1

      # Kill it without releasing.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # The GenServer's monitor must reclaim the leaked slot.
      wait_until(fn -> EC.tenant_count(t) == 0 end)
      assert EC.tenant_count(t) == 0
    end

    @tag :capture_log
    test "release-then-immediate-exit does NOT double-decrement the shared global (no under-count)" do
      # Regression for the cap-bypass bug: release/1 used to decrement ETS directly
      # AND the :DOWN handler decremented again, so tenant B's release + crash
      # decremented the GLOBAL counter TWICE — stealing tenant A's live slot from
      # the count and admitting MORE than max_global.
      a = tid()
      b = tid()

      # Tenant A holds a live slot in a kept-alive process: global == 1.
      {p_a, :ok} = acquire_in_held_process(a)
      wait_until(fn -> EC.global_count() >= 1 end)
      global_with_a = EC.global_count()
      assert global_with_a >= 1
      assert EC.tenant_count(a) == 1

      # Tenant B: acquire, release, then exit immediately (so a :DOWN races the
      # release). The decrement must happen EXACTLY ONCE for B.
      parent = self()

      {:ok, p_b} =
        Task.start(fn ->
          :ok = EC.acquire(b)
          :ok = EC.release(b)
          send(parent, :b_released)
          # Exit immediately after release — the :DOWN must NOT decrement again.
        end)

      ref = Process.monitor(p_b)
      assert_receive :b_released, 1_000
      assert_receive {:DOWN, ^ref, :process, ^p_b, _}, 1_000

      # Give the GenServer a beat to process any (now no-op) :DOWN.
      _ = :sys.get_state(EC)

      # B's slot is fully released (count back to 0 for B)...
      assert EC.tenant_count(b) == 0
      # ...and crucially A's live slot is STILL counted — the global never dropped
      # below A's live contribution (no under-count → no cap bypass).
      assert EC.global_count() == global_with_a,
             "global under-counted: #{EC.global_count()} < #{global_with_a} — " <>
               "tenant A's live slot was stolen by a double-decrement"

      assert EC.tenant_count(a) == 1

      release_held_process(p_a, a)
    end

    @tag :capture_log
    test "double release/1 is idempotent (second is a no-op)" do
      a = tid()
      {p_a, :ok} = acquire_in_held_process(a)
      wait_until(fn -> EC.global_count() >= 1 end)
      before = EC.global_count()

      # A second tenant whose held process releases TWICE.
      b = tid()
      parent = self()

      pid =
        spawn(fn ->
          :ok = EC.acquire(b)
          send(parent, :acquired)

          receive do
            :go ->
              :ok = EC.release(b)
              # Second release must be a no-op (pid no longer tracked).
              :ok = EC.release(b)
              send(parent, :done)
          end
        end)

      assert_receive :acquired, 1_000
      send(pid, :go)
      assert_receive :done, 1_000
      _ = :sys.get_state(EC)

      assert EC.tenant_count(b) == 0
      # A's slot survives both of B's releases.
      assert EC.global_count() == before
      assert EC.tenant_count(a) == 1

      release_held_process(p_a, a)
    end
  end

  # --- helpers ---

  # Run `fun` in a short-lived separate process and return its result. Used so an
  # "acquire" is charged to a DIFFERENT process than the caller (the per-process
  # monitor would otherwise treat two acquires from one pid as one).
  defp from_other_process(fun) do
    parent = self()
    spawn(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, r} -> r
    after
      1_000 -> flunk("from_other_process timed out")
    end
  end

  # Acquire in a process that stays alive holding the slot until released. Returns
  # {pid, acquire_result}.
  defp acquire_in_held_process(t) do
    parent = self()

    pid =
      spawn(fn ->
        r = EC.acquire(t)
        send(parent, {:acquired, self(), r})

        receive do
          :release ->
            EC.release(t)
            send(parent, {:released, self()})
        end
      end)

    receive do
      {:acquired, ^pid, r} -> {pid, r}
    after
      1_000 -> flunk("acquire_in_held_process timed out")
    end
  end

  defp release_held_process(pid, _t) do
    send(pid, :release)

    receive do
      {:released, ^pid} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
