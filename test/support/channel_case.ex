defmodule LoopctlWeb.ChannelCase do
  @moduledoc """
  The test case for Phoenix channel tests (issue #801, the runner channel).

  Same sandbox, Mox and default-stub setup as `LoopctlWeb.ConnCase`, with
  `Phoenix.ChannelTest` imported instead of `Phoenix.ConnTest`. Channel processes started
  by `connect/3` and `subscribe_and_join/3` inherit the test's `$callers`, so their DB
  calls run on the test's sandbox connection under `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint LoopctlWeb.Endpoint

      import Phoenix.ChannelTest
      import LoopctlWeb.ChannelCase
      import Loopctl.Fixtures
      import Mox
    end
  end

  setup tags do
    Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    Loopctl.DataCase.stub_all_defaults()
    :ok
  end

  @doc """
  Polls `fun` until it returns a truthy value or `timeout_ms` elapses, and returns the
  last value. For state that converges asynchronously, like a Presence entry removed
  when its tracked process exits.
  """
  @spec eventually((-> term()), non_neg_integer()) :: term()
  def eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_eventually(fun, deadline)
        else
          falsy
        end

      truthy ->
        truthy
    end
  end
end
