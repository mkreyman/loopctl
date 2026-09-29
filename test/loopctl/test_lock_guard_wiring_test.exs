defmodule Loopctl.Test.LockGuardWiringTest do
  @moduledoc """
  The async half of `Loopctl.Test.LockGuardTest`: an async DataCase test's setup records the
  backend PID of each guarded repo, which is what its registered teardown checks.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Test.LockGuard

  test "an async test's setup records a PID per guarded repo", context do
    pids = context.lock_guard_backend_pids

    assert length(pids) == length(LockGuard.guarded_repos())
    assert Enum.all?(pids, &(is_integer(&1) and &1 > 0))
  end
end
