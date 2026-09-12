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
  Pids from the launcher's tree file ("pid start-time" lines) that are still the same
  process: a recorded pid whose start time no longer matches has been reused.
  """
  @spec recorded(String.t() | nil) :: [pos_integer()]
  def recorded(nil), do: []

  def recorded(tree_file) do
    case File.read(tree_file) do
      {:ok, raw} ->
        starts = start_times()

        for line <- String.split(raw, "\n", trim: true),
            [pid_s, start] <- [String.split(line, " ", parts: 2)],
            {pid, ""} <- [Integer.parse(pid_s)],
            Map.get(starts, pid) == squeeze(start),
            do: pid

      {:error, _} ->
        []
    end
  end

  # `ps lstart` pads a one-digit day with a second space ("Tue Sep  8"); the launcher's awk
  # collapses it. Compared raw, every recorded pid mismatched on days 1-9.
  defp squeeze(start), do: start |> String.split() |> Enum.join(" ")

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

  defp start_times do
    for line <- ps_rows(["-A", "-o", "pid=,lstart="]),
        [pid_s, start] <- [String.split(String.trim_leading(line), " ", parts: 2)],
        into: %{},
        do: {String.to_integer(pid_s), squeeze(start)}
  end

  defp ps_rows(args) do
    {out, _} = System.cmd("ps", args, stderr_to_stdout: true)
    String.split(out, "\n", trim: true)
  end

  @type opts :: [
          marker: String.t() | nil,
          tree_file: String.t() | nil,
          leader_start: String.t() | nil
        ]

  @doc "The start time of `pid` as `ps lstart` prints it, whitespace-normalised, or nil."
  @spec start_time(pos_integer()) :: String.t() | nil
  def start_time(pid) when is_integer(pid) and pid > 1 do
    case System.cmd("ps", ["-o", "lstart=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} -> squeeze(out)
      _ -> nil
    end
  end

  # Whether `pgid` still names OUR group. A live group whose id is our launcher's pid is
  # ours unless a process with that pid is alive and started at a different time: then the
  # launcher died, its group emptied, and the pid was recycled into a stranger's group
  # leader. With the leader dead, the group id is held by our own stragglers — the kernel
  # does not reuse a pid while it is a live process group id. Without a recorded start
  # time only the group's liveness can be checked.
  defp ours?(nil, _leader_start), do: false
  defp ours?(_pgid, nil), do: true

  defp ours?(pgid, leader_start) do
    case start_time(pgid) do
      nil -> true
      ^leader_start -> true
      _other -> false
    end
  end

  @doc """
  TERM the group and every process belonging to the session, wait up to `grace_ms`, then
  KILL and wait again.

  A session's processes are its group, its current descendants, the processes carrying
  `:marker`, and the still-live pids in `:tree_file`. `pgid` may be nil to end only the
  latter, for a group that is no longer ours; with `:leader_start` (the launcher's start
  time) a `pgid` recycled into someone else's group is treated as nil.
  """
  @spec terminate(pos_integer() | nil, non_neg_integer(), opts()) :: outcome()
  def terminate(pgid, grace_ms, opts \\ []) do
    pgid = if ours?(pgid, opts[:leader_start]), do: pgid

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

    (marked(opts[:marker]) ++ recorded(opts[:tree_file]) ++ descendants(walk_from))
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

  @doc """
  Runs a short-lived command with a hard timeout, killing it on expiry.

  `System.cmd/3` has no timeout, and a probe that hangs must not wedge the session
  monitor that called it.
  """
  @spec run(String.t(), [String.t()], pos_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :timeout}
  def run(executable, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"ANTHROPIC_API_KEY", false}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline, [])
  end

  defp collect(port, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, os_pid, deadline, [acc, data])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        target = if leader?(os_pid), do: "-#{os_pid}", else: "#{os_pid}"
        System.cmd("kill", ["-KILL", "--", target], stderr_to_stdout: true)
        await_exit(port, System.monotonic_time(:millisecond) + 2_000)
        {:error, :timeout}
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
