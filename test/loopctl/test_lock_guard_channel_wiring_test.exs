defmodule Loopctl.Test.LockGuardChannelWiringTest do
  @moduledoc """
  `LoopctlWeb.ChannelCase` carries the same sandbox wiring as DataCase: an async channel test
  records the backend PID of each of its sandbox connections for the teardown lock check.
  """

  use LoopctlWeb.ChannelCase, async: true

  alias Loopctl.Test.LockGuard

  test "an async channel test's setup records its sandbox connections", context do
    actual = Enum.map(Loopctl.DataCase.sandbox_repos(), &LockGuard.backend_pid/1)
    assert context.lock_guard_backend_pids == actual
  end
end
