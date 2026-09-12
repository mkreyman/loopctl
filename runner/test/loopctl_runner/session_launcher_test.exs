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
            env: [{~c"LOOP_SESSION_ID", to_charlist(session_id)}, {~c"LOOP_KILL_GRACE_S", ~c"1"}]
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(test, {:os_pid, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:os_pid, os_pid}, 2_000
    :ok = wait_until(fn -> File.exists?(Path.join(state, "detached_pid")) end)
    {owner, os_pid}
  end

  defp pids(state),
    do: Enum.map(~w(grandchild_pid detached_pid), &read_int!(Path.join(state, &1)))

  test "the launcher leads its own process group, and a group signal alone misses detached children",
       ctx do
    {owner, os_pid} = spawn_owner(ctx)
    assert ProcessGroup.leader?(os_pid)
    assert read_int!(Path.join(ctx.state, "launcher_pid")) == os_pid
    [grandchild, detached] = pids(ctx.state)
    assert detached in ProcessGroup.marked(ctx.marker)

    # Without the marker: the group dies, the Bash-tool-shaped child does not.
    assert ProcessGroup.terminate(os_pid, 2_000) == :terminated
    refute os_pid_alive?(grandchild)
    assert os_pid_alive?(detached)

    # With it, the survivor is found and ended.
    assert ProcessGroup.terminate(nil, 2_000, ctx.marker) == :terminated
    refute os_pid_alive?(detached)
    assert ProcessGroup.marked(ctx.marker) == []
    Process.exit(owner, :kill)
  end

  test "the whole tree dies when the Port's owner dies without any teardown", ctx do
    {owner, os_pid} = spawn_owner(ctx)
    [grandchild, detached] = pids(ctx.state)
    assert os_pid_alive?(grandchild) and os_pid_alive?(detached)

    # No terminate/2, no Session: the owner is killed, the Port closes, and only the
    # launcher's stdin watchdog is left to act.
    Process.exit(owner, :kill)

    assert :ok = wait_until(fn -> ProcessGroup.marked(ctx.marker) == [] end, 8_000)
    refute ProcessGroup.alive?(os_pid)
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

  test "exit_reason/2: a CLI that exits 0 during a park stop exited on its own" do
    assert Session.exit_reason(:parked, 0) == :exited
    assert Session.exit_reason(:parked, 143) == :parked
    assert Session.exit_reason(nil, 7) == :exited
    assert Session.exit_reason(:wall_clock_exceeded, 0) == :wall_clock_exceeded
  end

  test "marked/1 matches whole environment entries only" do
    assert ProcessGroup.marked(nil) == []
    assert ProcessGroup.marked(ProcessGroup.marker("no-such-session")) == []
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
