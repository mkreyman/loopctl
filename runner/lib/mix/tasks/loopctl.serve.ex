defmodule Mix.Tasks.Loopctl.Serve do
  @shortdoc "Runs the runner daemon in the foreground: connects to loopctl and stays joined"

  @moduledoc """
      mix loopctl.serve [--config PATH] [--accept-dispatches]

  The same process the release runs under systemd or launchd, for development.

  ## Dispatches are refused unless you ask for them

  This task starts the IDENTICAL daemon on the IDENTICAL config, and `control.accepts_dispatches`
  is true on an enrolled machine — so without this default a foreground run here would take REAL
  production dispatches. That matters more than it sounds: a session inherits the environment the
  daemon was started from, and this one is YOUR LOGIN SHELL. Under systemd the daemon's
  environment is the unit's and carries no credential at all; a login shell on minis carried 41
  names matching token/secret/key/password/api/credential on 2026-09-16. `LoopctlRunner.Session`
  subtracts what it knows by name and by shape, and a subtraction over an environment nobody
  enumerated cannot be complete — so the environment is removed here rather than filtered there.

  The runner still JOINS: joining, reporting status and reconnecting are what this task is for,
  and it is the accepting that is dangerous. Dispatches are refused as `dispatches_disabled` —
  a `LoopctlRunner.DispatchPolicy` reason about this process's configuration, never a capability
  statement about the machine, which is what `kind_not_supported` would have been.

  `--accept-dispatches` restores the config's own answer, for the case that needs it: exercising
  the accept path deliberately, usually against a local fake loopctl.
  """

  use Mix.Task

  alias LoopctlRunner.Application, as: RunnerApp

  @impl Mix.Task
  def run(argv) do
    configure(argv)
    Mix.Task.run("app.start")
    Process.sleep(:infinity)
  end

  @doc """
  Everything this task decides BEFORE the application boots, as its own function.

  Separated so the default is testable: `run/1` ends in `Process.sleep(:infinity)`, so a test
  that called it would never return, and the dangerous half of this task is the half that runs
  before the daemon starts.
  """
  @spec configure([String.t()]) :: :ok
  def configure(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [config: :string, accept_dispatches: :boolean])

    if path = opts[:config], do: System.put_env("LOOPCTL_RUNNER_CONFIG", Path.expand(path))
    System.put_env("LOOPCTL_RUNNER_DAEMON", "1")
    announce(opts[:accept_dispatches])
    :ok
  end

  # Said out loud, because the default is the surprising half: an operator who expected this
  # daemon to take work needs to see why it did not, in the foreground where they are looking.
  defp announce(true) do
    System.delete_env(RunnerApp.refuse_dispatches_var())

    Mix.shell().info(
      "loopctl.serve: --accept-dispatches given; this runner will take REAL dispatches, " <>
        "and each session inherits this shell's environment"
    )
  end

  defp announce(_not_given) do
    System.put_env(RunnerApp.refuse_dispatches_var(), "1")

    Mix.shell().info(
      "loopctl.serve: joining, and refusing every dispatch as dispatches_disabled; " <>
        "pass --accept-dispatches to take them"
    )
  end
end
