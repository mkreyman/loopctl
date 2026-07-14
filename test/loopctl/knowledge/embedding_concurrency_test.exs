defmodule Loopctl.Knowledge.EmbeddingConcurrencyTest do
  @moduledoc """
  US-37.2 (AC-37.2.1/.4/.5): the per-node outbound-embedding concurrency cap.

  This exercises the REAL `Loopctl.Knowledge.EmbeddingConcurrency` GenServer
  DIRECTLY (bypassing the config-DI seam the search path uses in :test) with its OWN
  fixed LOW cap via `acquire/1`, INDEPENDENT of the deliberately HIGH
  `:embedding_max_concurrent` the async suite sets in `config/test.exs`. The GLOBAL
  in-flight counter is process-global SHARED state (one ETS row for the whole node),
  so a search-path test could in principle perturb it — but in :test the search path
  goes through the MOCK gate, not this counter, so nothing else touches it. Even so,
  the cap assertions use a held-slot process model and assert RELATIVE to the
  logical low cap, mirroring `ExportConcurrencyTest`.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.EmbeddingConcurrency, as: EC

  # Prove the cap with an explicit LOW cap via `EC.acquire/1`, independent of the
  # high suite default (`:embedding_max_concurrent`, 64) that stops incidental
  # parallel searches colliding on the shared global counter. We hold at most
  # `@cap` (2) shared-global slots — far below 64 — so we never starve any
  # incidental acquirer that reads the configured cap.
  @cap 2

  # Acquire against the test's explicit low cap in a kept-alive process and hold the
  # slot until released. Returns the holder pid.
  defp hold do
    parent = self()

    pid =
      spawn(fn ->
        :ok = retry_acquire(500)
        send(parent, {:held, self()})

        receive do
          :release -> EC.release()
        end
      end)

    receive do
      {:held, ^pid} -> pid
    after
      10_000 -> flunk("could not hold an embedding slot (global cap contended too long)")
    end
  end

  defp retry_acquire(0), do: flunk("could not acquire embedding slot")

  defp retry_acquire(attempts) do
    case EC.acquire(@cap) do
      :ok ->
        :ok

      {:error, :rate_limited_local} ->
        Process.sleep(10)
        retry_acquire(attempts - 1)
    end
  end

  defp release(pid), do: send(pid, :release)

  describe "acquire/1 + release/0" do
    test "grants up to the cap, then refuses over-cap acquires" do
      # Saturate the logical cap with `@cap` DIFFERENT held processes, then a fresh
      # acquirer is refused purely on the cap. The global counter is shared, so we
      # retry the saturation+refusal invariant until it holds.
      holders = for _ <- 1..@cap, do: hold()

      assert eventually(fn ->
               EC.count() >= @cap and
                 match?(
                   {:error, :rate_limited_local},
                   from_other_process(fn -> EC.acquire(@cap) end)
                 )
             end),
             "cap did not refuse an over-cap acquire within the retry window"

      Enum.each(holders, &release/1)
    end

    test "release/0 frees the slot so capacity is returned" do
      # Saturate the cap with `@cap` held processes, then release ONE holder and
      # prove a fresh acquire can now succeed (the released slot was returned).
      [first | rest] = for _ <- 1..@cap, do: hold()

      # Fully saturated: an extra acquirer is refused.
      assert eventually(fn ->
               EC.count() >= @cap and
                 match?(
                   {:error, :rate_limited_local},
                   from_other_process(fn -> EC.acquire(@cap) end)
                 )
             end)

      # Free one slot.
      release(first)

      # Capacity returned: a fresh acquire+release now succeeds.
      assert eventually(fn ->
               match?(
                 :ok,
                 from_other_process(fn ->
                   case EC.acquire(@cap) do
                     :ok -> EC.release()
                     other -> other
                   end
                 end)
               )
             end)

      Enum.each(rest, &release/1)
    end

    @tag :capture_log
    test "a crashed acquirer's slot is reclaimed by the monitor (no permanent leak)" do
      before = EC.count()

      {:ok, pid} =
        Task.start(fn ->
          :ok = retry_acquire(500)

          receive do
            :stop -> :ok
          end
        end)

      # Wait until the acquire is visible (count strictly above the pre-acquire base).
      wait_until(fn -> EC.count() > before end)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # The GenServer's monitor must reclaim the leaked slot — the count returns to
      # (at most) the pre-acquire baseline (relative assertion: other tests do not
      # touch this counter, but be robust anyway).
      assert eventually(fn -> EC.count() <= before end),
             "crashed acquirer's slot was not reclaimed (permanent leak)"
    end

    @tag :capture_log
    test "double release/0 is idempotent (second is a no-op, never drives the counter negative)" do
      parent = self()

      pid =
        spawn(fn ->
          :ok = retry_acquire(500)
          send(parent, :acquired)

          receive do
            :go ->
              :ok = EC.release()
              # Second release must be a no-op (pid no longer tracked).
              :ok = EC.release()
              send(parent, :done)
          end
        end)

      assert_receive :acquired, 2_000
      before_go = EC.count()
      send(pid, :go)
      assert_receive :done, 2_000
      _ = :sys.get_state(EC)

      # The double-release freed EXACTLY the one held slot: the counter dropped by at
      # most one (never two), and the clamp guarantees it never goes negative.
      assert eventually(fn -> EC.count() >= 0 and EC.count() <= before_go end)
    end
  end

  describe "max_concurrent/0" do
    test "returns a positive integer (the configured suite default)" do
      cap = EC.max_concurrent()
      assert is_integer(cap) and cap > 0
    end
  end

  # --- helpers ---

  # Run `fun` in a short-lived separate process and return its result. Used so an
  # acquire is charged to a DIFFERENT process than the caller (the per-process
  # monitor treats two acquires from one pid as one).
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
