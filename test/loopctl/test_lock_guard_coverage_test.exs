defmodule Loopctl.Test.LockGuardCoverageTest do
  @moduledoc """
  The teardown lock check actually RAN for every async test that recorded its PIDs.

  `async: false` is the point: ExUnit runs every async module, teardowns included, before any
  sync one, so when this runs the two counters `Loopctl.Test.LockGuard` keeps are final for
  the async half of the suite. Only the wiring moves them — `DataCase.setup_sandbox/1` and
  `LockGuard.start_owner!/1` count a setup, their teardowns count a check — so a teardown
  that stops passing the PIDs, or stops calling the check, leaves them unequal.
  """

  use ExUnit.Case, async: false

  alias Loopctl.Test.LockGuard

  test "every async setup that recorded PIDs had them checked at teardown" do
    {setups, teardowns, _skipped} = LockGuard.stats()

    # Run alone, with no async module before it, there is nothing to compare.
    if setups > 0 do
      assert teardowns == setups,
             "#{setups} async setups recorded PIDs but only #{teardowns} teardowns checked them"
    end
  end
end
