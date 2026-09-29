defmodule Loopctl.Test.LockGuardWiringTest do
  @moduledoc """
  The async half of `Loopctl.Test.LockGuardTest`: an async DataCase test's setup records the
  backend PID of each of its sandbox connections, which is what its registered teardown checks.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Test.LockGuard

  test "an async test's setup records the backend PID of each of its sandbox connections",
       context do
    actual = Enum.map(Loopctl.DataCase.sandbox_repos(), &LockGuard.backend_pid/1)

    assert context.lock_guard_backend_pids == actual
    assert length(Enum.uniq(actual)) == length(actual)
  end
end
