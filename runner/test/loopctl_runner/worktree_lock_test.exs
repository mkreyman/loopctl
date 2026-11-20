defmodule LoopctlRunner.WorktreeLockTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.WorktreeLock
  import LoopctlRunner.TestSupport

  setup do
    {:ok, runs: tmp_dir!("locks"), path: "/tree/#{System.unique_integer([:positive])}"}
  end

  # Takes the lock from a process of its own, as a run's task does.
  defp taken_by_process(ctx, run_id, fun) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:taken, WorktreeLock.acquire(ctx.runs, ctx.path, run_id, owner!())})
        fun.()
      end)

    assert_receive {:taken, :ok}, 5_000
    pid
  end

  test "a live run's lock is held", ctx do
    pid = taken_by_process(ctx, "live-run", fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert WorktreeLock.live_holder(ctx.runs, ctx.path) == "live-run"

    assert WorktreeLock.acquire(ctx.runs, ctx.path, "next-run", owner!()) ==
             {:error, {:held, "live-run"}}
  end

  test "release is only the holder's", ctx do
    assert WorktreeLock.acquire(ctx.runs, ctx.path, "mine", owner!()) == :ok
    assert WorktreeLock.release(ctx.runs, ctx.path, "someone-else") == :ok
    assert WorktreeLock.live_holder(ctx.runs, ctx.path) == "mine"
    assert WorktreeLock.release(ctx.runs, ctx.path, "mine") == :ok
    assert WorktreeLock.live_holder(ctx.runs, ctx.path) == nil
  end

  test "release_held_by frees every lock of that run, and no other run's", ctx do
    other = "/tree/other-#{System.unique_integer([:positive])}"
    assert WorktreeLock.acquire(ctx.runs, ctx.path, "dead", owner!()) == :ok
    assert WorktreeLock.acquire(ctx.runs, other, "live", owner!()) == :ok

    assert WorktreeLock.release_held_by(ctx.runs, "dead") == [ctx.path]
    assert WorktreeLock.live_holder(ctx.runs, ctx.path) == nil
    assert WorktreeLock.live_holder(ctx.runs, other) == "live"
  end
end
