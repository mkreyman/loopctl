defmodule LoopctlRunner.ProcessGroup do
  @moduledoc """
  Ending a Claude Code session's whole process tree, on Linux and macOS alike.

  A session is an OS process tree, never a BEAM process, and `Port.close/1` closes pipes
  and nothing more. Signalling the launcher's process group is NOT enough either,
  measured on Claude Code 2.1.270: the Bash tool runs every command in a NEW SESSION
  (its own sid and pgid), and the CLI's MCP servers are separate trees too. A group TERM
  happens to work because the CLI cleans up its children on TERM; a group KILL, or a CLI
  that exited without cleaning up, leaves them running, reparented to init, where no
  parent walk can find them.

  What does reach them is the environment. The runner sets `LOOP_SESSION_ID=<uuid>` on
  the Port and every descendant inherits it — the Bash tool's detached shells and the
  MCP servers included (measured). So a session is ended by signalling its group AND
  every process whose environment carries that marker: TERM, a grace period, then KILL.
  The marker is also what makes the boot-time reaper safe against pid reuse.

  MuonTrap would contain this with cgroups, which exist on one of the three enrolled
  machines.
  """

  alias LoopctlRunner.{Owner, Session}

  @poll_ms 200

  @type outcome :: :already_gone | :terminated | :killed | {:error, :survived}

  @doc "The environment marker for a session."
  @spec marker(String.t()) :: String.t()
  def marker(session_id), do: "LOOP_SESSION_ID=" <> session_id

  @doc "True when any process is still in group `pgid`."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pgid) when is_integer(pgid) and pgid > 1 do
    match?({_, 0}, System.cmd("kill", ["-0", "--", "-#{pgid}"], stderr_to_stdout: true))
  end

  @doc "True when `pid` is its own process group leader."
  @spec leader?(pos_integer()) :: boolean()
  def leader?(pid) when is_integer(pid) and pid > 1 do
    case System.cmd("ps", ["-o", "pgid=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == Integer.to_string(pid)
      _ -> false
    end
  end

  @doc "The command line of `pid`, or nil when it is not running."
  @spec command(pos_integer()) :: String.t() | nil
  def command(pid) when is_integer(pid) and pid > 1 do
    case System.cmd("ps", ["-o", "command=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  Pids of this user's processes whose environment carries `marker`.

  On Linux `ps` prints every process's environment. On macOS it can only read the
  environment of non-Apple binaries (node, beam), so a detached `/bin/bash` or `sleep` is
  invisible here and must be found through the launcher's tree file (`recorded/1`).
  The `ps` this spawns cannot match: the BEAM's own environment has no marker.
  """
  @spec marked(String.t() | nil) :: [pos_integer()]
  def marked(nil), do: []

  def marked(marker) do
    own = String.to_integer(System.pid())

    for line <- ps_rows(env_ps_args()),
        marked_line?(line, marker),
        {pid, _} <- [Integer.parse(String.trim_leading(line))],
        pid != own,
        do: pid
  end

  defp env_ps_args do
    case :os.type() do
      {:unix, :darwin} -> ["-A", "-E", "-ww", "-o", "pid=,command="]
      _ -> ["axeww", "-o", "pid=,command="]
    end
  end

  # A whole environment entry, not a prefix of a longer value.
  defp marked_line?(line, marker) do
    String.contains?(line, " " <> marker <> " ") or String.ends_with?(line, " " <> marker)
  end

  @doc """
  Pids from the launcher's tree file ("pid boot:<id>:<ticks>" on Linux, "pid utc:<lstart>"
  elsewhere, untagged from a runner before #66) that are still the same process: a recorded pid
  whose start no longer matches has been reused.
  """
  @spec recorded(String.t() | nil, [{String.t(), String.t()}]) :: [pos_integer()]
  def recorded(tree_file, env \\ []),
    do: for({pid, _start} <- recorded_entries(tree_file, env), do: pid)

  @doc """
  `recorded/1`, keeping each pid's start time as the tree file recorded it.

  The start time is the FILE's, not a fresh reading: it was captured by whoever wrote the
  line, at the moment it detached the process, which is the only moment a writer knows a
  start time a later pid reuse cannot counterfeit. A caller that pins these pids into a
  tree file of its own has to write that value, since re-reading it after this scan would
  hand a stranger the line meant for a process that has since exited.
  """
  #
  # `env` is the reader's environment for its `ps` snapshots (see `Owner.start_time/2`).
  @spec recorded_entries(String.t() | nil, [{String.t(), String.t()}]) ::
          [{pos_integer(), String.t()}]
  def recorded_entries(tree_file, env \\ [])
  def recorded_entries(nil, _env), do: []

  def recorded_entries(tree_file, env) do
    case File.read(tree_file) do
      {:ok, raw} ->
        entries =
          for line <- String.split(raw, "\n", trim: true),
              [pid_s, raw_start] <- [String.split(line, " ", parts: 2)],
              {pid, ""} <- [Integer.parse(pid_s)],
              do: {pid, Owner.normalize_start(raw_start)}

        snapshots = snapshots(entries, env)
        for entry <- entries, live?(entry, snapshots), do: entry

      {:error, _} ->
        []
    end
  end

  @doc "Current descendants of `root`, walked by parent pid."
  @spec descendants(pos_integer() | nil) :: [pos_integer()]
  def descendants(nil), do: []

  def descendants(root) do
    parents =
      for line <- ps_rows(["-A", "-o", "pid=,ppid="]),
          [pid_s, ppid_s] <- [String.split(line)],
          do: {String.to_integer(pid_s), String.to_integer(ppid_s)}

    walk(parents, MapSet.new([root])) |> MapSet.delete(root) |> MapSet.to_list()
  end

  defp walk(parents, set) do
    grown =
      Enum.reduce(parents, set, fn {pid, ppid}, acc ->
        if MapSet.member?(acc, ppid), do: MapSet.put(acc, pid), else: acc
      end)

    if MapSet.size(grown) == MapSet.size(set), do: set, else: walk(parents, grown)
  end

  # A line is compared only in its own form. `"boot:..."` — the launcher's on Linux — is the
  # kernel's start (`Owner.start_id/1`, a /proc read, no process spawned). `"utc:..."` is compared
  # against one UTC `ps -A` snapshot, and an untagged line, written by a runner before #66, against
  # one in this process's own zone; each snapshot is taken only when a line of its form exists.
  # A snapshot that could not be taken verifies nothing, and an unverified pid is never signalled:
  # a stranger that reused it would be killed.
  defp snapshots(entries, env) do
    forms = entries |> Enum.map(fn {_pid, start} -> form(start) end) |> MapSet.new()

    %{
      # The pids alive now, listed once: a tree file is never pruned, so most of a long
      # session's boot: lines name processes long gone, and each needs no /proc read of its own.
      boot: if(:boot in forms, do: live_pids(), else: :cannot_tell),
      utc: if(:utc in forms, do: Owner.utc_starts(env), else: :cannot_tell),
      local: if(:local in forms, do: Owner.local_starts(env), else: :cannot_tell)
    }
  end

  # Unlistable reads as "maybe alive", so each boot: line is still read on its own.
  defp alive_in?({:ok, pids}, pid), do: MapSet.member?(pids, pid)
  defp alive_in?(:cannot_tell, _pid), do: true

  defp live_pids do
    case File.ls("/proc") do
      {:ok, names} ->
        {:ok, for(name <- names, {pid, ""} <- [Integer.parse(name)], into: MapSet.new(), do: pid)}

      {:error, _} ->
        :cannot_tell
    end
  end

  defp form("boot:" <> _), do: :boot
  defp form("utc:" <> _), do: :utc
  defp form(_legacy), do: :local

  defp live?({pid, start}, snapshots) do
    case form(start) do
      :boot -> alive_in?(snapshots.boot, pid) and Owner.start_id(pid) == start
      snapshot -> match?({:ok, %{^pid => ^start}}, Map.fetch!(snapshots, snapshot))
    end
  end

  defp ps_rows(args) do
    {out, _} = System.cmd("ps", args, stderr_to_stdout: true)
    String.split(out, "\n", trim: true)
  end

  @type opts :: [
          marker: String.t() | nil,
          tree_file: String.t() | nil,
          leader_start: String.t() | nil,
          leader_start_id: String.t() | nil,
          ps_env: [{String.t(), String.t()}]
        ]

  # Whether `pgid` still names OUR group. A live group whose id is our launcher's pid is
  # ours unless a process with that pid is alive and started at a different time: then the
  # launcher died, its group emptied, and the pid was recycled into a stranger's group
  # leader. With the leader dead, the group id is held by our own stragglers — the kernel
  # does not reuse a pid while it is a live process group id. Without a recorded start
  # time only the group's liveness can be checked.
  #
  # The launcher's start is `leader_start_id` (`Owner.start_id/1`), which neither a timezone nor a
  # clock step moves; a run a runner before #66 recorded carries only `leader_start`, in that
  # runner's zone. ONE reading either way, so a leader cannot exit between two and pass as a
  # stranger.
  defp ours?(nil, _opts), do: false

  defp ours?(pgid, opts) do
    case {opts[:leader_start_id], opts[:leader_start]} do
      {nil, nil} ->
        true

      {nil, legacy} when is_binary(legacy) ->
        same_leader?(
          Owner.local_start_time(pgid, opts[:ps_env] || []),
          Owner.normalize_start(legacy)
        )

      # A start in no form this reads names no leader it could vouch for, as before #66.
      {nil, _unreadable} ->
        false

      {started, _legacy} ->
        same_leader?(Owner.start_id(pgid, opts[:ps_env] || []), started)
    end
  end

  defp same_leader?(nil, _recorded), do: true
  defp same_leader?(now, recorded), do: now == recorded

  @doc """
  TERM the group and every process belonging to the session, wait up to `grace_ms`, then
  KILL and wait again.

  A session's processes are its group, its current descendants, the processes carrying
  `:marker`, and the still-live pids in `:tree_file`. `pgid` may be nil to end only the
  latter, for a group that is no longer ours; with `:leader_start_id` or `:leader_start` (the
  launcher's start, as `Owner.start_id/1` or a runner before #66 recorded it) a `pgid` recycled
  into someone else's group is treated as nil.
  """
  @spec terminate(pos_integer() | nil, non_neg_integer(), opts()) :: outcome()
  def terminate(pgid, grace_ms, opts \\ []) do
    pgid = if ours?(pgid, opts), do: pgid

    if gone?(pgid, opts) do
      :already_gone
    else
      signal_all(pgid, opts, "TERM")
      await_gone(pgid, opts, grace_ms, :terminated) || kill(pgid, opts, grace_ms)
    end
  end

  defp kill(pgid, opts, grace_ms) do
    signal_all(pgid, opts, "KILL")
    await_gone(pgid, opts, grace_ms, :killed) || {:error, :survived}
  end

  # The parent walk only while the group lives: a live group id cannot be a recycled pid,
  # but once the group is gone `pgid` may name an unrelated process with children of its own.
  defp members(pgid, opts) do
    walk_from = if pgid != nil and alive?(pgid), do: pgid

    (marked(opts[:marker]) ++
       recorded(opts[:tree_file], opts[:ps_env] || []) ++ descendants(walk_from))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == pgid))
  end

  defp signal_all(pgid, opts, signal) do
    targets =
      Enum.map(members(pgid, opts), &Integer.to_string/1) ++
        if(pgid, do: ["-#{pgid}"], else: [])

    if targets != [],
      do: System.cmd("kill", ["-#{signal}", "--" | targets], stderr_to_stdout: true)
  end

  defp gone?(pgid, opts), do: not (pgid != nil and alive?(pgid)) and members(pgid, opts) == []

  defp await_gone(pgid, opts, remaining_ms, outcome) do
    cond do
      gone?(pgid, opts) ->
        outcome

      remaining_ms <= 0 ->
        nil

      true ->
        Process.sleep(@poll_ms)
        await_gone(pgid, opts, remaining_ms - @poll_ms, outcome)
    end
  end

  # What the runner's OWN commands never inherit (`run/5`): the session's billing key, from the one
  # place that names it, plus credentials and credential-acquisition paths the runner's own git
  # and probes do not need. A session is scrubbed differently, and far less (`Session.unset_names/0`):
  # it inherits the operator's environment as an attended session does. These are the runner acting
  # for itself, so a name here reaches one of its commands only through `inherit:`.
  #
  # SSH_AUTH_SOCK, SSH_AGENT_PID and GPG_AGENT_INFO are sockets to agents holding the operator's
  # keys. GH_TOKEN and GITHUB_TOKEN are forge tokens. The askpass pair is a credential-ACQUISITION
  # path: git falls through GIT_ASKPASS -> core.askPass -> SSH_ASKPASS, so both names are needed,
  # and `Worktree.fetch_base/3` closes the config rung itself with an empty `core.askPass`.
  @runner_credential_env ~w(SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO GH_TOKEN GITHUB_TOKEN
                            GIT_ASKPASS SSH_ASKPASS)

  @doc "Every name `run/5` unsets by NAME. The shape deny (`credential_shaped_env/1`) is separate."
  @spec scrubbed_env() :: [String.t()]
  def scrubbed_env, do: Session.credential_env() ++ @runner_credential_env

  # THE NAME LIST ABOVE CANNOT ENUMERATE AN OPERATOR'S LOGIN SHELL: `mix loopctl.serve` runs the
  # daemon from it, where 41 names matching token/secret/key/password/api/credential were counted on
  # minis, 2026-09-16. A heuristic, not a guarantee: it catches the conventional spellings and
  # misses a credential named for what it opens (a bare `NPM_AUTH`, a `PGPASSFILE`).
  @credential_shapes ~w(TOKEN SECRET PASSWORD PASSWD PASSPHRASE CREDENTIAL API_KEY PRIVATE_KEY)

  @doc """
  Whether `name` has the SHAPE of a credential, whatever this runner knows about it by name.

  Matched case-insensitively against the conventional spellings, plus a `_KEY` suffix or infix,
  which is what `AWS_SECRET_ACCESS_KEY`, `HEX_API_KEY` and `FLY_API_TOKEN` have in common and
  what `HOME`, `PATH`, `LANG`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS` do not.
  """
  @spec credential_shaped?(String.t()) :: boolean()
  def credential_shaped?(name) do
    up = String.upcase(name)

    Enum.any?(@credential_shapes, &String.contains?(up, &1)) or
      String.ends_with?(up, "_KEY") or String.contains?(up, "_KEY_")
  end

  @doc "The names in `env` that have a credential's shape, sorted."
  @spec credential_shaped_env(%{String.t() => String.t()}) :: [String.t()]
  def credential_shaped_env(env) do
    env
    |> Map.keys()
    |> Enum.filter(&credential_shaped?/1)
    |> Enum.sort()
  end

  @doc """
  Runs a short-lived command with a hard timeout, killing it on expiry.

  `System.cmd/3` has no timeout, and a probe that hangs must not wedge the session
  monitor that called it.

  `env` is `{name, value}` pairs set ON TOP of the credential scrub below, `nil` unsetting one; it
  can add to the scrub, never take a name out of it, so a caller can never hand a scrubbed name a
  value of its own choosing.

  `inherit:` (in `opts`) is the one way a scrubbed name reaches the child, and only with the value
  the runner itself has: those names are left out of the scrub, and are otherwise untouched. The
  runner's own `Worktree.fetch_base/3` names the operator's ssh agent and forge token this way,
  because it authenticates as the operator does. A name that is unset in the runner stays unset.

  A Port child is its own session leader with no controlling terminal (measured on OTP 28, Linux
  and macOS), so nothing it starts can prompt on the operator's tty, and on timeout its whole group
  is killed — the children it started go with it, not only its own pid.
  """
  @spec run(String.t(), [String.t()], pos_integer(), [{String.t(), String.t() | nil}], keyword()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :timeout}
  def run(executable, args, timeout_ms, env \\ [], opts \\ []) do
    inherit = Keyword.get(opts, :inherit, [])

    # Rejected, never `--`: a name can be on both lists (GH_TOKEN is named AND has the shape), and
    # `--` takes out one occurrence only.
    scrubbed =
      Enum.reject(
        scrubbed_env() ++ credential_shaped_env(System.get_env()),
        &(&1 in inherit)
      )

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        # THE RUNNER'S OWN SCRUB, NOT A SESSION'S. A session inherits the operator's environment
        # (`Session.unset_names/0`); what runs here is the runner acting for itself — the liveness
        # probe (`claude agents --json`), the base fetch, the submodule step — and none of it needs
        # a credential it does not name through `inherit:`. GIT_SSH_COMMAND and GIT_SSH are
        # deliberately NOT unset, though this Port does run git. The runner's own `Worktree.fetch_base/3` goes
        # through here and must reach origin with the operator's ssh program: it passes
        # GIT_SSH_COMMAND itself, with BatchMode added, and inherits a GIT_SSH program as it is;
        # scrubbing that would swap in plain ssh. The runner's own submodule step (`run_group/4`)
        # fetches for the operator from his own checkout, and `GIT_SSH_COMMAND` is how an operator
        # reaches a submodule over SSH.
        env:
          Enum.map(scrubbed, &{to_charlist(&1), false}) ++
            for {name, value} <- env, name not in scrubbed do
              {to_charlist(name), if(value, do: to_charlist(value), else: false)}
            end
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline, [], Keyword.get(opts, :term_grace_ms, 0))
  end

  # Leader of its own session (so of its own group) before the command is exec'd, exactly as
  # `session-launcher.sh` makes itself: `setsid` only when it is not already one, because a process
  # that already leads a group cannot call it (EPERM).
  @setsid_exec ~S|getpgrp() == $$ or POSIX::setsid() != -1 or die "setsid: $!\n"; | <>
                 ~S|exec { $ARGV[0] } @ARGV or die "exec: $!\n"|

  @doc """
  `run/5` for a command that starts children of its own, killing ALL of them on expiry.

  git's submodule step runs a helper, a clone and a transport under the process the Port starts.
  Here that process is made the leader of a new session before the command is exec'd, so the
  timeout's KILL is sent to its whole group and none of them outlives the call. OTP 27 and 28
  already start a Port child as a group leader (measured on macOS); this makes it a property of
  the function rather than of the runtime. A child that makes itself a session of its own (an
  `ssh` ControlPersist master) leaves the group, and nothing here reaches it.
  """
  @spec run_group(String.t(), [String.t()], pos_integer(), [{String.t(), String.t() | nil}]) ::
          {:ok, binary(), non_neg_integer()} | {:error, :timeout}
  def run_group(executable, args, timeout_ms, extra_env \\ []) do
    perl = System.find_executable("perl") || raise "perl is required to run #{executable}"
    run(perl, ["-MPOSIX", "-e", @setsid_exec, "--", executable | args], timeout_ms, extra_env)
  end

  # On expiry: with `term_grace_ms`, TERM first and that long to exit (git removes its own lock
  # files on TERM, and a KILL leaves them behind), then KILL.
  defp collect(port, os_pid, deadline, acc, grace_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, os_pid, deadline, [acc, data], grace_ms)
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        target = if leader?(os_pid), do: "-#{os_pid}", else: "#{os_pid}"

        unless grace_ms > 0 and terminated?(port, target, grace_ms) do
          System.cmd("kill", ["-KILL", "--", target], stderr_to_stdout: true)
          await_exit(port, System.monotonic_time(:millisecond) + 2_000)
        end

        {:error, :timeout}
    end
  end

  defp terminated?(port, target, grace_ms) do
    System.cmd("kill", ["-TERM", "--", target], stderr_to_stdout: true)
    exited?(port, System.monotonic_time(:millisecond) + grace_ms)
  end

  defp exited?(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> true
      {^port, {:data, _}} -> exited?(port, deadline)
    after
      remaining -> false
    end
  end

  # Consume the killed probe's own {:exit_status, _}. Closing the Port first would race
  # it: a status queued before the close lands in the CALLER's mailbox as a message from
  # a Port the caller does not know, and crashed the session monitor.
  # The deadline is fixed once: a child still writing to the pipe must not extend it.
  defp await_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> await_exit(port, deadline)
    after
      remaining -> safe_close(port)
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
