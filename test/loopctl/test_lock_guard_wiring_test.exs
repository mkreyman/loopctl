defmodule Loopctl.Test.LockGuardWiringTest do
  @moduledoc """
  The async half of `Loopctl.Test.LockGuardTest`: an async test's sandbox setup records the
  backend PID of every repo it checks out, which is what the teardown check reads.
  """

  use Loopctl.DataCase, async: true

  test "an async test's setup records a backend PID per repo for the teardown check", context do
    pids = context.lock_guard_backend_pids

    assert is_list(pids) and length(pids) == 3
    assert Enum.all?(pids, &(is_integer(&1) and &1 > 0))
  end
end
