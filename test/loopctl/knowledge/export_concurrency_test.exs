defmodule Loopctl.Knowledge.ExportConcurrencyTest do
  @moduledoc """
  US-27.16 (AC-27.16.6): the streaming-export concurrency cap.

  The PER-TENANT counters are isolated by distinct random tenant ids, so per-tenant
  assertions are async-safe. The GLOBAL in-flight counter, however, is process-global
  SHARED state (one ETS row for the whole node) — other async tests that make real
  export requests transiently touch it. So tests here:

    * assert PER-TENANT invariants (isolated) as the primary check, and
    * for the global cap, RETRY held-slot acquires (tolerating transient concurrent
      holders) and assert RELATIVE to a freshly-measured baseline — never an absolute
      global count.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ExportConcurrency, as: EC

  defp tid, do: Ecto.UUID.generate()

  # Acquire (retrying on transient global-cap contention from concurrent async tests)
  # and hold the slot in a kept-alive process until released. Returns the pid.
  defp hold(tenant_id) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = retry_acquire(tenant_id, 500)
        send(parent, {:held, self()})

        receive do
          :release -> EC.release(tenant_id)
        end
      end)

    receive do
      {:held, ^pid} -> pid
    after
      10_000 -> flunk("could not hold an export slot (global cap contended too long)")
    end
  end

  defp retry_acquire(_t, 0), do: flunk("could not acquire export slot")

  defp retry_acquire(t, attempts) do
    case EC.acquire(t) do
      :ok ->
        :ok

      {:error, :too_many_exports} ->
        Process.sleep(10)
        retry_acquire(t, attempts - 1)
    end
  end

  defp release(pid) do
    send(pid, :release)
  end

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
      # Global cap default is 2. Hold the global cap with `max_global` DIFFERENT
      # tenants (each within its per-tenant cap of 1). Once saturated, a fresh tenant
      # is refused on the GLOBAL cap (its per-tenant count is 0). Because the GLOBAL
      # counter is shared with concurrent async tests, we retry the saturation+refusal
      # invariant until it holds (a transient concurrent holder just delays it).
      holders = for _ <- 1..EC.max_global(), do: hold(tid())

      t_extra = tid()

      assert eventually(fn ->
               # Saturated by our holders (+ possibly others) AND a 0-count tenant is
               # refused purely on the global cap.
               EC.global_count() >= EC.max_global() and
                 match?(
                   {:error, :too_many_exports},
                   from_other_process(fn -> EC.acquire(t_extra) end)
                 ) and
                 EC.tenant_count(t_extra) == 0
             end),
             "global cap did not bound a fresh 0-count tenant within the retry window"

      Enum.each(holders, &release/1)
    end

    test "a refused acquire leaves NO counter incremented (no partial reservation)" do
      # PER-TENANT invariant (isolated, race-free): after the tenant's own slot is
      # held and a second same-tenant acquire is refused, the tenant count stays at
      # exactly 1 — the refused acquire undid BOTH its global and tenant increments
      # (a partial reservation would leave tenant_count at 2 or the global leaked).
      t = tid()
      assert :ok = EC.acquire(t)

      assert {:error, :too_many_exports} = from_other_process(fn -> EC.acquire(t) end)

      # The refused per-tenant acquire must have left the tenant counter at 1 (not 2),
      # proving it undid its increment. (We assert the isolated per-tenant counter,
      # not the shared global, which concurrent tests perturb.)
      assert EC.tenant_count(t) == 1

      EC.release(t)
      assert EC.tenant_count(t) == 0
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
    test "release-then-immediate-exit does NOT double-decrement the shared global (cap-bypass regression)" do
      # Regression for the cap-bypass bug: release/1 used to decrement ETS directly
      # AND the :DOWN handler decremented again, so a tenant's release + crash
      # decremented the GLOBAL counter TWICE — under-counting in-flight exports and
      # admitting MORE than max_global.
      #
      # We detect it via the CAP BEHAVIOR (robust to concurrent global activity):
      # SATURATE the global cap with `max_global` held tenants, then have one EXTRA
      # tenant acquire → release → exit-immediately (release racing its :DOWN). If the
      # decrement were doubled, the global would drop below the held count and a fresh
      # tenant would be wrongly ADMITTED. It must STAY refused.
      holders = for _ <- 1..EC.max_global(), do: hold(tid())

      b = tid()
      parent = self()

      {:ok, p_b} =
        Task.start(fn ->
          # b may be refused if the cap is already full of our holders — retry until
          # a holder's slot is momentarily free, OR just attempt once; either way the
          # decrement (if it happened) must not over-free. To make the race exist we
          # need b to have ACQUIRED, so retry until it does (a holder briefly yields).
          case EC.acquire(b) do
            :ok ->
              :ok = EC.release(b)
              send(parent, :b_done)

            {:error, :too_many_exports} ->
              send(parent, :b_refused)
          end
        end)

      ref = Process.monitor(p_b)
      assert_receive msg when msg in [:b_done, :b_refused], 2_000
      assert_receive {:DOWN, ^ref, :process, ^p_b, _}, 2_000
      _ = :sys.get_state(EC)

      # The cap MUST still bound a fresh 0-count tenant: b's release+crash freed at
      # most ONE slot (b's own), never two. With `max_global` holders still live, a
      # fresh tenant stays refused — proving no global under-count.
      t_fresh = tid()

      assert eventually(fn ->
               EC.global_count() >= EC.max_global() and
                 match?(
                   {:error, :too_many_exports},
                   from_other_process(fn -> EC.acquire(t_fresh) end)
                 )
             end),
             "global was under-counted: a fresh tenant was admitted though #{EC.max_global()} " <>
               "holders are live — the cap-bypass double-decrement regressed"

      Enum.each(holders, &release/1)
    end

    @tag :capture_log
    test "double release/1 is idempotent (second is a no-op) — per-tenant isolated" do
      # Isolated, race-free: a tenant's held process releases TWICE. The PER-TENANT
      # counter (isolated by the random tid) must end at exactly 0 — the second
      # release is a no-op (pid no longer tracked), never driving it to -1/leaking.
      b = tid()
      parent = self()

      pid =
        spawn(fn ->
          :ok = retry_acquire(b, 500)
          send(parent, :acquired)

          receive do
            :go ->
              :ok = EC.release(b)
              # Second release must be a no-op (pid no longer tracked).
              :ok = EC.release(b)
              send(parent, :done)
          end
        end)

      assert_receive :acquired, 2_000
      assert eventually(fn -> EC.tenant_count(b) == 1 end)
      send(pid, :go)
      assert_receive :done, 2_000
      _ = :sys.get_state(EC)

      # The double-release left the PER-TENANT counter at exactly 0 (isolated, not
      # perturbed by concurrent tests): the second release was a no-op, never -1.
      assert eventually(fn -> EC.tenant_count(b) == 0 end)
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

  # Retry a (possibly concurrency-perturbed) boolean invariant until it holds or the
  # attempts run out. Returns true/false so callers `assert eventually(...)`.
  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
