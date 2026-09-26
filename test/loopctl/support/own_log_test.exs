defmodule Loopctl.OwnLogTest do
  use ExUnit.Case, async: true

  import Loopctl.OwnLog

  require Logger

  test "keeps the calling process's entries and drops another process's" do
    log =
      capture_own_log(fn ->
        Logger.warning("mine")

        {pid, ref} = spawn_monitor(fn -> Logger.warning("foreign") end)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end)

    assert log =~ "mine"
    refute log =~ "foreign"
  end

  test "keeps every line of a multi-line entry" do
    log = capture_own_log(fn -> Logger.warning("head\ntail with DBConnection") end)

    assert log =~ "head"
    assert log =~ "tail with DBConnection"
  end

  test "with_own_log returns the function's result alongside the log" do
    assert {4, log} = with_own_log(fn -> Logger.warning("four") && 2 + 2 end)
    assert log =~ "four"
  end
end
