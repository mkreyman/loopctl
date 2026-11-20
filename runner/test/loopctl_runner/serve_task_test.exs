defmodule LoopctlRunner.ServeTaskTest do
  @moduledoc """
  `mix loopctl.serve` starts the identical daemon on the identical config, from the operator's
  LOGIN SHELL, and `control.accepts_dispatches` is true on an enrolled machine — so its default
  is what stands between a foreground dev run and a real dispatch whose session inherits that
  shell. The default is the thing to test, and `run/1` ends in `Process.sleep(:infinity)`, which
  is why the pre-boot half is `configure/1`.
  """

  # Mutates the OS environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LoopctlRunner.Application, as: RunnerApp
  alias Mix.Tasks.Loopctl.Serve

  setup do
    marker = RunnerApp.refuse_dispatches_var()
    saved = {System.get_env(marker), System.get_env("LOOPCTL_RUNNER_DAEMON")}

    on_exit(fn ->
      {refuse, daemon} = saved
      restore(marker, refuse)
      restore("LOOPCTL_RUNNER_DAEMON", daemon)
    end)

    {:ok, marker: marker}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "with no flag the task refuses dispatches, and says so", %{marker: marker} do
    System.delete_env(marker)

    out = capture_io(fn -> assert Serve.configure([]) == :ok end)

    assert System.get_env(marker) == "1"
    overrides = RunnerApp.foreground_overrides()
    assert overrides[:accepts_dispatches] == false
    # The refusal that reaches loopctl says WHICH dispatches_disabled this is, and names the way
    # out; asserted here by substance, not by exact wording.
    assert overrides[:dispatch_refusal_detail] =~ "mix loopctl.serve"
    assert overrides[:dispatch_refusal_detail] =~ "--accept-dispatches"
    # The default is the surprising half, so the operator has to be told in the foreground.
    assert out =~ "refusing every dispatch"
    assert out =~ "--accept-dispatches"
    # It still becomes a daemon: joining is what the task is for.
    assert System.get_env("LOOPCTL_RUNNER_DAEMON") == "1"
  end

  test "--accept-dispatches hands the decision back to the config", %{marker: marker} do
    # Set first, so this proves the flag CLEARS the marker rather than merely not setting it: a
    # previous run in the same shell would otherwise keep refusing with no way to tell why.
    System.put_env(marker, "1")

    out = capture_io(fn -> assert Serve.configure(["--accept-dispatches"]) == :ok end)

    refute System.get_env(marker)
    assert RunnerApp.foreground_overrides() == []
    assert out =~ "REAL dispatches"
  end
end
