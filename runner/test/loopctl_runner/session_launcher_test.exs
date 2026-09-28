defmodule LoopctlRunner.SessionLauncherTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{ProcessGroup, Session}
  import LoopctlRunner.TestSupport

  @moduletag timeout: 30_000

  setup do
    state = tmp_dir!("launcher")
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}])
    on_exit(restore)
    session_id = Session.uuid4()
    {:ok, state: state, session_id: session_id, marker: ProcessGroup.marker(session_id)}
  end

  defp spawn_owner(%{state: state, session_id: session_id}) do
    test = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, Session.launcher_script()}, [
            :binary,
            :exit_status,
            args: [Path.join(state, "stderr.log"), headless_launcher(), "-p", "x"],
            env: [
              {~c"LOOP_SESSION_ID", to_charlist(session_id)},
              {~c"LOOP_KILL_GRACE_S", ~c"1"},
              {~c"LOOP_TREE_POLL_S", ~c"1"}
            ]
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(test, {:os_pid, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:os_pid, os_pid}, 2_000
    :ok = wait_until(fn -> File.exists?(Path.join(state, "detached_pid")) end)
    detached = read_int!(Path.join(state, "detached_pid"))
    :ok = wait_until(fn -> recorded?(tree_file(state), detached) end)
    {owner, os_pid}
  end

  defp tree_file(state), do: Path.join(state, "stderr.log.tree")

  defp pids(state),
    do: Enum.map(~w(grandchild_pid detached_pid), &read_int!(Path.join(state, &1)))

  test "the launcher leads its own process group, and only the tree file finds an orphaned detached child",
       ctx do
    {owner, os_pid} = spawn_owner(ctx)
    assert ProcessGroup.leader?(os_pid)
    assert read_int!(Path.join(ctx.state, "launcher_pid")) == os_pid
    [grandchild, detached] = pids(ctx.state)
    assert detached in ProcessGroup.recorded(tree_file(ctx.state))

    # A bare group KILL — no descendant walk, no marker, no tree: the group dies, the
    # Bash-tool-shaped child does not, and its parent is gone so nothing links it back.
    {_, 0} = System.cmd("kill", ["-KILL", "--", "-#{os_pid}"])
    :ok = wait_until(fn -> not ProcessGroup.alive?(os_pid) end)
    refute os_pid_alive?(grandchild)
    assert os_pid_alive?(detached)
    assert ProcessGroup.descendants(os_pid) == []

    # With it, the survivor is found and ended.
    # The tree file alone, no marker: the only mechanism macOS has for this child.
    assert ProcessGroup.terminate(nil, 2_000, tree_file: tree_file(ctx.state)) == :terminated
    refute os_pid_alive?(detached)
    assert ProcessGroup.recorded(tree_file(ctx.state)) == []
    Process.exit(owner, :kill)
  end

  test "the whole tree dies when the Port's owner dies without any teardown", ctx do
    {owner, os_pid} = spawn_owner(ctx)
    [grandchild, detached] = pids(ctx.state)
    assert os_pid_alive?(grandchild) and os_pid_alive?(detached)

    # No terminate/2, no Session: the owner is killed, the Port closes, and only the
    # launcher's stdin watchdog is left to act.
    Process.exit(owner, :kill)

    assert :ok = wait_until(fn -> not os_pid_alive?(detached) end, 8_000)
    assert :ok = wait_until(fn -> not ProcessGroup.alive?(os_pid) end, 8_000)
    refute os_pid_alive?(grandchild)
    refute os_pid_alive?(detached)
  end

  test "a message from a Port the session does not own does not crash it", ctx do
    root = tmp_dir!("stray")
    config = config!(root, %{"liveness_interval_s" => 60})
    {:ok, story} = LoopctlRunner.Story.from_map(story_map(%{"wall_clock_s" => 3}), config)
    run_dir = Path.join(root, "run")
    File.mkdir_p!(run_dir)
    {:ok, trace} = LoopctlRunner.Trace.start_link(Path.join(run_dir, "trace.ndjson"), "stray")

    {:ok, pid} =
      GenServer.start(Session,
        config: config,
        story: story,
        worktree: ctx.state,
        run_dir: run_dir,
        trace: trace,
        parent: nil,
        waiter: self()
      )

    ref = Process.monitor(pid)
    stranger = Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", "exit 0"])
    send(pid, {stranger, {:exit_status, 137}})

    assert_receive {:session_result, ^pid, %{reason: :wall_clock_exceeded}}, 15_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "a session already marked parked that then exits 0 is recorded as exited", ctx do
    System.put_env("FAKE_CLAUDE_MODE", "quiet_then_result")
    root = tmp_dir!("parked-exit")
    config = config!(root, %{"liveness_interval_s" => 60})
    {:ok, story} = LoopctlRunner.Story.from_map(story_map(), config)
    run_dir = Path.join(root, "run")
    File.mkdir_p!(run_dir)
    {:ok, trace} = LoopctlRunner.Trace.start_link(Path.join(run_dir, "trace.ndjson"), "pe")

    {:ok, pid} =
      GenServer.start(Session,
        config: config,
        story: story,
        worktree: ctx.state,
        run_dir: run_dir,
        trace: trace,
        parent: nil,
        waiter: self()
      )

    # The instant between a park verdict and its TERM, frozen: the stop is recorded but
    # the CLI finishes on its own.
    :sys.replace_state(pid, &Map.put(&1, :reason, :parked))

    assert_receive {:session_result, ^pid, %{reason: :exited, exit_status: 0}}, 15_000
  end

  test "a timed-out probe returns on time even while a detached child keeps writing", ctx do
    writer = Path.join(ctx.state, "writer_pid")

    perl = Path.join(ctx.state, "writer.pl")

    File.write!(perl, """
    use POSIX;
    POSIX::setsid();
    open(my $f, ">", "#{writer}"); print $f $$; close $f;
    $| = 1;
    while (1) { print "x\\n"; select(undef, undef, undef, 0.05) }
    """)

    script = "perl #{perl} & exec sleep 30"

    on_exit(fn ->
      if File.exists?(writer), do: System.cmd("kill", ["-KILL", File.read!(writer)])
    end)

    {micros, result} = :timer.tc(fn -> ProcessGroup.run("/bin/sh", ["-c", script], 300) end)
    assert result == {:error, :timeout}
    assert micros < 4_000_000
  end

  test "an escalation recorded while a park stop is under way makes the session escalated", ctx do
    System.put_env("FAKE_CLAUDE_MODE", "escalate_later_and_exit")
    root = tmp_dir!("park-escalate")
    config = config!(root, %{"liveness_interval_s" => 60})
    {:ok, story} = LoopctlRunner.Story.from_map(story_map(), config)
    run_dir = Path.join(root, "run")
    File.mkdir_p!(run_dir)
    {:ok, trace} = LoopctlRunner.Trace.start_link(Path.join(run_dir, "trace.ndjson"), "pe")

    {:ok, pid} =
      GenServer.start(Session,
        config: config,
        story: story,
        worktree: ctx.state,
        run_dir: run_dir,
        trace: trace,
        parent: nil,
        waiter: self()
      )

    :sys.replace_state(pid, &Map.put(&1, :reason, :parked))

    assert_receive {:session_result, ^pid, %{reason: :escalated, exit_status: 0}}, 15_000
  end

  test "exit_reason/2: a CLI that exits 0 during a park stop exited on its own" do
    assert Session.exit_reason(:parked, 0) == :exited
    assert Session.exit_reason(:parked, 143) == :parked
    assert Session.exit_reason(nil, 7) == :exited
    assert Session.exit_reason(:wall_clock_exceeded, 0) == :wall_clock_exceeded
  end

  test "a detached command naming the launcher script is still ended when the owner dies", ctx do
    System.put_env("FAKE_CLAUDE_MODE", "hang_named")
    test = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, Session.launcher_script()}, [
            :binary,
            :exit_status,
            args: [Path.join(ctx.state, "stderr.log"), headless_launcher(), "-p", "x"],
            env: [
              {~c"LOOP_SESSION_ID", to_charlist(ctx.session_id)},
              {~c"LOOP_KILL_GRACE_S", ~c"1"},
              {~c"LOOP_TREE_POLL_S", ~c"1"}
            ]
          ])

        send(test, {:os_pid, Port.info(port, :os_pid)})
        Process.sleep(:infinity)
      end)

    assert_receive {:os_pid, {:os_pid, _}}, 2_000
    :ok = wait_until(fn -> File.exists?(Path.join(ctx.state, "named_pid")) end)
    named = read_int!(Path.join(ctx.state, "named_pid"))
    :ok = wait_until(fn -> recorded?(tree_file(ctx.state), named) end)
    assert ProcessGroup.command(named) =~ "session-launcher.sh"

    Process.exit(owner, :kill)
    assert :ok = wait_until(fn -> not os_pid_alive?(named) end, 8_000)
  end

  test "recorded/1 matches start times whatever ps's day padding" do
    {out, 0} = System.cmd("/bin/sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
    pid = String.to_integer(String.trim(out))
    on_exit(fn -> System.cmd("kill", ["#{pid}"]) end)
    {lstart, 0} = System.cmd("ps", ["-o", "lstart=", "-p", "#{pid}"])
    file = Path.join(tmp_dir!("padding"), "tree")

    # Padded the way ps pads a one-digit day, and collapsed the way awk writes it.
    padded = lstart |> String.trim() |> String.replace(" ", "  ")
    File.write!(file, "#{pid} #{padded}\n")
    assert pid in ProcessGroup.recorded(file)

    collapsed = lstart |> String.split() |> Enum.join(" ")
    File.write!(file, "#{pid} #{collapsed}\n")
    assert pid in ProcessGroup.recorded(file)
  end

  test "terminate never walks the children of a pid that is not a live group" do
    # A non-leader parent with a child: what a recycled launcher pid could turn out to be.
    marker_file = Path.join(tmp_dir!("recycled"), "parent_pid")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", "sh -c 'echo $$ > #{marker_file}; sleep 30; :' & sleep 30 & wait"]
      ])

    # Captured now: by on_exit the test process is gone and so is the Port.
    {:os_pid, leader} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", "--", "-#{leader}"]) end)

    :ok = wait_until(fn -> File.exists?(marker_file) end)
    stranger = read_int!(marker_file)
    :ok = wait_until(fn -> ProcessGroup.descendants(stranger) != [] end)
    [child] = ProcessGroup.descendants(stranger)
    refute ProcessGroup.leader?(stranger)
    refute ProcessGroup.alive?(stranger)

    assert ProcessGroup.terminate(stranger, 300) == :already_gone
    assert os_pid_alive?(stranger)
    assert os_pid_alive?(child)
  end

  test "terminate leaves alone a group whose leader pid was recycled into a stranger" do
    # A stranger leading its own group, under the pid a dead launcher once had.
    {out, 0} =
      System.cmd("/bin/sh", [
        "-c",
        ~s|perl -MPOSIX -e 'POSIX::setsid(); exec "sleep", "30"' >/dev/null 2>&1 & echo $!|
      ])

    stranger = String.to_integer(String.trim(out))
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{stranger}"]) end)
    :ok = wait_until(fn -> ProcessGroup.leader?(stranger) end)

    assert ProcessGroup.terminate(stranger, 300, leader_start: "Thu Jan 1 00:00:00 1970") ==
             :already_gone

    assert os_pid_alive?(stranger)

    # With its real start time it is ours, and it is ended.
    assert ProcessGroup.terminate(stranger, 2_000,
             leader_start: LoopctlRunner.Owner.start_time(stranger)
           ) ==
             :terminated
  end

  test "marked/1 matches whole environment entries only" do
    assert ProcessGroup.marked(nil) == []
    assert ProcessGroup.marked(ProcessGroup.marker("no-such-session")) == []
  end

  test "ProcessGroup.run_group kills the command's CHILDREN on timeout, not only the command" do
    # git's submodule step runs a helper, a clone and a transport under the process the Port
    # started. A kill of that process alone leaves them running, unsupervised, holding the tree.
    pid_file = Path.join(tmp_dir!("run-group"), "child_pid")
    script = "sleep 30 & echo $! > #{pid_file}; wait"

    assert {:error, :timeout} = ProcessGroup.run_group("/bin/sh", ["-c", script], 500)
    child = pid_file |> File.read!() |> String.trim()
    on_exit(fn -> System.cmd("kill", ["-KILL", child], stderr_to_stdout: true) end)

    assert :ok = wait_until(fn -> not os_pid_alive?(child) end, 3_000)
  end

  test "ProcessGroup.run_group runs the command as the leader of its own group" do
    assert {:ok, out, 0} =
             ProcessGroup.run_group("/bin/sh", ["-c", "echo $$ $(ps -o pgid= -p $$)"], 5_000)

    assert [pid, pid] = String.split(out)
  end

  test "ProcessGroup.run's timeout kills what the command started, not only the command" do
    # The runner's own git fetch runs here, and ssh or a credential helper is its child: killed by
    # pid alone, git would die and leave them running.
    child = Path.join(tmp_dir!("run-group"), "child_pid")

    assert {:error, :timeout} =
             ProcessGroup.run("/bin/sh", ["-c", "sleep 30 & echo $! > #{child}; wait"], 300)

    pid = child |> File.read!() |> String.trim()

    :ok =
      wait_until(fn ->
        not match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
      end)
  end

  test "ProcessGroup.run kills a probe that outlives its timeout" do
    for _ <- 1..10 do
      assert {:error, :timeout} = ProcessGroup.run("/bin/sh", ["-c", "exec sleep 30"], 50)
    end

    # The killed probe's exit_status must not be left for the caller to trip over.
    Process.sleep(200)
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({port, _} when is_port(port), &1))

    assert {:ok, "hi\n", 0} = ProcessGroup.run("/bin/sh", ["-c", "echo hi"], 2_000)
  end
end
