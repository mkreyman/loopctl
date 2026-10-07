defmodule Loopctl.CallTrace do
  @moduledoc """
  The local calls the CALLING process makes to given functions while a function runs.

  How a test pins that a production entry point routes through the function the other
  tests prove — `acquire/1` through the guarded `acquire/4`, the read path's arity-0
  entry through the key it documents — without taking down or rewriting the node-wide
  state that entry point uses. Tracing is scoped to the calling process, so no other
  test's calls are observed; the trace messages go to a collector process.
  """

  import ExUnit.Assertions

  @doc "Runs `fun` and returns the `{module, function, args}` calls it made to `mfas`, in order."
  @spec calls([mfa()], (-> term())) :: [{module(), atom(), [term()]}]
  def calls(mfas, fun) do
    collector = spawn_link(fn -> collect([]) end)
    Enum.each(mfas, fn mfa -> assert :erlang.trace_pattern(mfa, true, [:local]) == 1 end)
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
    end

    send(collector, {:report, self()})

    receive do
      {:calls, calls} -> calls
    after
      2_000 -> flunk("the trace collector never reported")
    end
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, mfa} -> collect([mfa | acc])
      {:report, pid} -> send(pid, {:calls, Enum.reverse(acc)})
    end
  end
end
