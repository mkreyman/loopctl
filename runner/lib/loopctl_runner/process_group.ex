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

  `ps axeww` prints each command followed by its environment on both procps and BSD ps.
  The `ps` this spawns cannot match: the BEAM's own environment has no marker.
  """
  @spec marked(String.t() | nil) :: [pos_integer()]
  def marked(nil), do: []

  def marked(marker) do
    {out, _} = System.cmd("ps", ["axeww", "-o", "pid=,command="], stderr_to_stdout: true)
    own = String.to_integer(System.pid())

    for line <- String.split(out, "\n", trim: true),
        marked_line?(line, marker),
        {pid, _} <- [Integer.parse(String.trim_leading(line))],
        pid != own,
        do: pid
  end

  # A whole environment entry, not a prefix of a longer value.
  defp marked_line?(line, marker) do
    String.contains?(line, " " <> marker <> " ") or String.ends_with?(line, " " <> marker)
  end

  @doc """
  TERM the group and every marked process, wait up to `grace_ms`, then KILL and wait again.

  `pgid` may be nil to end only the marked processes, for a group that is no longer ours.
  """
  @spec terminate(pos_integer() | nil, non_neg_integer(), String.t() | nil) :: outcome()
  def terminate(pgid, grace_ms, marker \\ nil) do
    if gone?(pgid, marker) do
      :already_gone
    else
      signal_all(pgid, marker, "TERM")
      await_gone(pgid, marker, grace_ms, :terminated) || kill(pgid, marker, grace_ms)
    end
  end

  defp kill(pgid, marker, grace_ms) do
    signal_all(pgid, marker, "KILL")
    await_gone(pgid, marker, grace_ms, :killed) || {:error, :survived}
  end

  defp signal_all(pgid, marker, signal) do
    targets =
      Enum.map(marked(marker), &Integer.to_string/1) ++ if(pgid, do: ["-#{pgid}"], else: [])

    if targets != [],
      do: System.cmd("kill", ["-#{signal}", "--" | targets], stderr_to_stdout: true)
  end

  defp gone?(pgid, marker), do: not (pgid != nil and alive?(pgid)) and marked(marker) == []

  defp await_gone(pgid, marker, remaining_ms, outcome) do
    cond do
      gone?(pgid, marker) ->
        outcome

      remaining_ms <= 0 ->
        nil

      true ->
        Process.sleep(@poll_ms)
        await_gone(pgid, marker, remaining_ms - @poll_ms, outcome)
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
