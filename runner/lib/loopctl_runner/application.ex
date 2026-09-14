defmodule LoopctlRunner.Application do
  @moduledoc """
  Starts the runner daemon only when asked to.

  `mix loopctl.run` also boots this application, and a hand-filed run must never join the
  machine pool, so the control connection starts only under `LOOPCTL_RUNNER_DAEMON=1` —
  which the systemd unit and the launchd agent set — or through `mix loopctl.serve`.
  """

  use Application

  alias LoopctlRunner.{Config, Control}

  @impl true
  def start(_type, _args) do
    children = if daemon?(), do: daemon_children!(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: LoopctlRunner.Supervisor)
  end

  defp daemon?, do: System.get_env("LOOPCTL_RUNNER_DAEMON") == "1"

  @doc """
  Checks, before a release is installed, everything the daemon needs to start: the config
  loads, it has a control section, and the token file is readable by this user alone.
  Prints each failure and halts non-zero, so `rel/install.sh` refuses to switch releases.
  """
  @spec preflight() :: :ok | no_return()
  def preflight do
    case preflight_check() do
      {:ok, path} ->
        IO.puts("preflight ok: #{path}")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "preflight failed: #{reason}")
        System.halt(1)
    end
  end

  @doc false
  @spec preflight_check() :: {:ok, String.t()} | {:error, String.t()}
  def preflight_check do
    path = System.get_env("LOOPCTL_RUNNER_CONFIG") || Config.default_path()

    with {:ok, config} <- Config.load(path),
         {:ok, control} <- control_section(config, path),
         {:ok, _token} <- LoopctlRunner.ControlConfig.read_token(control) do
      {:ok, path}
    end
  end

  defp control_section(%Config{control: nil}, path),
    do: {:error, "#{path} has no control section"}

  defp control_section(%Config{control: control}, _path), do: {:ok, control}

  @doc """
  The daemon's children for the config at `LOOPCTL_RUNNER_CONFIG` (default
  `~/.config/loopctl-runner/runner.json`). Raises on a bad config: a daemon that cannot
  read its allow-list must not start.
  """
  @spec daemon_children!() :: [{module(), keyword()}]
  def daemon_children! do
    path = System.get_env("LOOPCTL_RUNNER_CONFIG") || Config.default_path()

    case Config.load(path) do
      {:ok, %Config{control: nil}} ->
        raise "runner config #{path} has no control section; the daemon has nothing to connect to"

      {:ok, config} ->
        # Primary metadata, so every process's lines carry the runner id, supervisor reports
        # about Control included. Lines logged before the config loads cannot.
        :logger.update_primary_config(%{metadata: %{runner_id: config.control.runner_id}})
        # Accepted runs live under their own supervisor, started before Control so it exists
        # whenever a dispatch is accepted. A run is a synchronous Run.execute in a task: Control
        # is never blocked by one, and a Control restart does not take running sessions down.
        [
          {Task.Supervisor, name: LoopctlRunner.RunSupervisor},
          {Control, config: config, name: Control, run_supervisor: LoopctlRunner.RunSupervisor}
        ]

      {:error, reason} ->
        raise "refusing to start the runner daemon: #{reason}"
    end
  end
end
