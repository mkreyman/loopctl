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
    # Before anything can judge an owner: every mix task, the daemon and the suite start here.
    LoopctlRunner.Owner.init_outage_counter()
    children = if daemon?(), do: daemon_children!(), else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: LoopctlRunner.Supervisor)
  end

  defp daemon?, do: System.get_env("LOOPCTL_RUNNER_DAEMON") == "1"

  # How `mix loopctl.serve` tells this daemon to refuse work. The prefix is not incidental:
  # `Session.release_env/1` unsets every LOOPCTL_RUNNER_* name for a session, so this marker
  # cannot reach the thing it exists to protect against.
  @refuse_dispatches_var "LOOPCTL_RUNNER_REFUSE_DISPATCHES"

  # What the refusal says on the wire. `dispatches_disabled` is one reason for two conditions —
  # a machine configured not to take work, and this — and loopctl cannot tell them apart from the
  # reason alone, so whoever reads it there guesses which machine is misconfigured. It carries no
  # path, hostname or environment value: this string leaves the machine.
  @foreground_detail "a foreground mix loopctl.serve run refuses dispatches by default, " <>
                       "so this machine's configuration was not consulted; " <>
                       "restart it with --accept-dispatches to use the config's answer"

  @doc false
  @spec refuse_dispatches_var() :: String.t()
  def refuse_dispatches_var, do: @refuse_dispatches_var

  @doc """
  Control options the foreground dev task forces on this daemon, or `[]` under a service manager.

  `mix loopctl.serve` runs the identical daemon on the identical config, from the operator's
  LOGIN SHELL, and an enrolled machine's `control.accepts_dispatches` is true — so the task
  refuses work unless it was asked for it (`--accept-dispatches`), and this is the wire.

  It is TWO options, not one, because a session starts by two paths. The decision path is
  `accepts_dispatches: false` below. The other is recovery: `Control.init/1` resends the accept
  of a crashed predecessor's pending start and runs it on `ok`, WITHOUT consulting
  `DispatchPolicy` — the accept was already given — so a foreground run over a service daemon's
  `runs_dir` would start a real session in the login shell. `restores_pending_starts: false`
  closes that one, leaving the entries for the service daemon.

  The refusal is expressed as `accepts_dispatches: false`, which `LoopctlRunner.DispatchPolicy`
  answers `dispatches_disabled`: a statement about how THIS PROCESS is configured, which is what
  a foreground dev task is. It is deliberately not a capability reason — `kind_not_supported`
  would tell loopctl this MACHINE never runs that kind, which is a lie a dev session would leave
  behind it. It also reports `draining: true` on the join (`Control.reported_draining/2`), so
  loopctl reserves no capacity here for a session that would not start; the runner still joins,
  which is what the task is for.
  """
  @spec foreground_overrides() :: keyword()
  def foreground_overrides do
    if System.get_env(@refuse_dispatches_var) == "1",
      do: [
        accepts_dispatches: false,
        dispatch_refusal_detail: @foreground_detail,
        restores_pending_starts: false
      ],
      else: []
  end

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
        Config.warn_if_hook_cannot_see_grants(config)
        # Accepted runs live under their own supervisor, started before Control so it exists
        # whenever a dispatch is accepted. A run is a synchronous Run.execute in a task: Control
        # is never blocked by one, and a Control restart does not take running sessions down.
        [
          {Task.Supervisor, name: LoopctlRunner.RunSupervisor},
          {Control,
           [config: config, name: Control, run_supervisor: LoopctlRunner.RunSupervisor] ++
             foreground_overrides()}
        ]

      {:error, reason} ->
        raise "refusing to start the runner daemon: #{reason}"
    end
  end
end
