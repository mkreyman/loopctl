defmodule Mix.Tasks.Loopctl.Serve do
  @shortdoc "Runs the runner daemon in the foreground: connects to loopctl and stays joined"

  @moduledoc """
      mix loopctl.serve [--config PATH]

  The same process the release runs under systemd or launchd, for development.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [config: :string])
    if path = opts[:config], do: System.put_env("LOOPCTL_RUNNER_CONFIG", Path.expand(path))
    System.put_env("LOOPCTL_RUNNER_DAEMON", "1")
    Mix.Task.run("app.start")
    Process.sleep(:infinity)
  end
end
