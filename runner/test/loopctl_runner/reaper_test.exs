defmodule LoopctlRunner.ReaperTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    Owner,
    ProcessGroup,
    Reaper,
    RunState,
    Session,
    Trace,
    Worktree,
    WorktreeLock
  }

  import LoopctlRunner.TestSupport

  @moduletag timeout: 30_000

  setup do
    root = tmp_dir!("reaper")
    repo = git_repo!(Path.join(root, "repo"))
    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}])
    on_exit(restore)
    {:ok, root: root, repo: repo, state: state, runs: Path.join(root, "runs")}
  end

  # A launcher whose watchdog never fires: its stdin is a pipe held open by a process
  # outside its group, the situation a failed watchdog leaves behind. Started from a
  # shell rather than a Port, so it also exercises the perl setsid path.
  defp orphan_launcher!(state, session_id) do
    fifo = Path.join(state, "stdin.fifo")

    script = """
    mkfifo #{fifo}
    sleep 1000 > #{fifo} 2>/dev/null &
    echo $! > #{state}/holder_pid
    LOOP_SESSION_ID=#{session_id} #{Session.launcher_script()} #{state}/stderr.log #{headless_launcher()} -p x < #{fifo} >/dev/null 2>&1 &
    """

    {_, 0} = System.cmd("/bin/sh", ["-c", script])
    holder = Path.join(state, "holder_pid")
    on_exit(fn -> System.cmd("kill", ["-KILL", holder |> File.read!() |> String.trim()]) end)
    :ok = wait_until(fn -> File.exists?(Path.join(state, "detached_pid")) end)
    read_int!(Path.join(state, "launcher_pid"))
  end

  defp dead_pid do
    {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
    String.to_integer(String.trim(out))
  end

  test "an in-flight run whose BEAM is gone has its group killed and worktree removed", ctx do
    session_id = Session.uuid4()
    pgid = orphan_launcher!(ctx.state, session_id)
    assert ProcessGroup.leader?(pgid)
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")

    run_dir = Path.join(ctx.runs, "s1-run")
    File.mkdir_p!(run_dir)
    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), "s1-run")
    run_seq = Trace.emit(trace, "run.started", nil)
    Trace.close(trace)

    RunState.update(run_dir, %{
      run_id: "s1-run",
      run_seq: run_seq,
      status: "running",
      beam_os_pid: dead_pid(),
      pgid: pgid,
      session_id: session_id,
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "creating"}
    })

    assert [%{run_id: "s1-run", process_group: ":terminated"}] = Reaper.reap(ctx.runs, 2_000)
    refute ProcessGroup.alive?(pgid)
    refute os_pid_alive?(read_int!(Path.join(ctx.state, "grandchild_pid")))
    refute os_pid_alive?(read_int!(Path.join(ctx.state, "detached_pid")))
    assert ProcessGroup.marked(ProcessGroup.marker(session_id)) == []
    refute File.dir?(path)
    assert {:ok, %{"status" => "reaped"}} = RunState.read(run_dir)

    {:ok, events} = Trace.read(Path.join(run_dir, "trace.ndjson"))
    assert [_, %{"type" => "run.reaped", "parent" => ^run_seq}] = events
    assert {:ok, _} = Trace.tree(events)

    # Reaping is idempotent: a reaped run is not revisited.
    assert Reaper.reap(ctx.runs, 2_000) == []
  end

  test "a group whose leader is no longer our launcher is never signalled", ctx do
    # A live process group led by something that is not our launcher: a recycled pgid.
    leader = ~s|perl -MPOSIX -e 'POSIX::setsid(); exec "sleep", "30"' >/dev/null 2>&1 & echo $!|
    {out, 0} = System.cmd("/bin/sh", ["-c", leader])
    stranger = String.to_integer(String.trim(out))
    :ok = wait_until(fn -> ProcessGroup.leader?(stranger) end)
    run_dir = Path.join(ctx.runs, "reused")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "reused",
      run_seq: 0,
      status: "running",
      beam_os_pid: dead_pid(),
      pgid: stranger
    })

    assert [%{process_group: group}] = Reaper.reap(ctx.runs, 500)
    assert group =~ "not signalled"
    assert os_pid_alive?(stranger)
    System.cmd("kill", ["#{stranger}"])
  end

  test "marked processes are ended even when the group is gone", ctx do
    session_id = Session.uuid4()
    pgid = orphan_launcher!(ctx.state, session_id)
    detached = read_int!(Path.join(ctx.state, "detached_pid"))
    # The group dies on its own; the Bash-tool-shaped child does not.
    {_, 0} = System.cmd("kill", ["-KILL", "--", "-#{pgid}"])
    :ok = wait_until(fn -> not ProcessGroup.alive?(pgid) end)
    assert os_pid_alive?(detached)

    run_dir = Path.join(ctx.runs, "group-gone")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "group-gone",
      run_seq: 0,
      status: "running",
      beam_os_pid: dead_pid(),
      pgid: pgid,
      session_id: session_id
    })

    assert [%{process_group: ":terminated"}] = Reaper.reap(ctx.runs, 2_000)
    refute os_pid_alive?(detached)
  end

  describe "a crashed run's worktree that holds work" do
    for {label, make_work} <- [
          uncommitted: quote(do: fn path -> File.write!(Path.join(path, "wip.txt"), "wip") end),
          committed:
            quote(
              do: fn path ->
                File.write!(Path.join(path, "done.txt"), "done")
                git!(path, ["add", "done.txt"])
                git!(path, ["commit", "-q", "-m", "work"])
              end
            )
        ] do
      test "is kept on reap and adopted by a re-run (#{label})", ctx do
        path = Worktree.path_for(ctx.repo, "s1")
        {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
        unquote(make_work).(path)
        run_dir = Path.join(ctx.runs, "crashed")
        File.mkdir_p!(run_dir)

        RunState.update(run_dir, %{
          run_id: "crashed",
          run_seq: 0,
          status: "running",
          beam_os_pid: dead_pid(),
          repo_path: ctx.repo,
          worktree: %{path: path, branch: "loop/s1", base: "master", status: "creating"}
        })

        assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500)
        assert worktree =~ "kept"
        assert File.dir?(path)
        assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(run_dir)

        assert {:ok, %{reused: true}} = Worktree.create(ctx.repo, path, "loop/s1", "master")
      end
    end
  end

  test "a teardown that failed to remove its worktree is retried", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    run_dir = Path.join(ctx.runs, "finished")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "finished",
      run_seq: 0,
      status: "succeeded",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "remove_failed"}
    })

    assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500)
    assert worktree =~ ":removed"
    refute File.dir?(path)

    assert {:ok, %{"status" => "succeeded", "worktree" => %{"status" => "removed"}}} =
             RunState.read(run_dir)

    assert Reaper.reap(ctx.runs, 500) == []
  end

  test "an entry handed off to a later run is never acted on", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")

    for {id, wt_status} <- [{"old", "remove_failed"}, {"new", "creating"}] do
      dir = Path.join(ctx.runs, id)
      File.mkdir_p!(dir)

      owner = if id == "old", do: %{"beam_os_pid" => dead_pid()}, else: Owner.current()

      RunState.update(
        dir,
        Map.merge(owner, %{
          "run_id" => id,
          "run_seq" => 0,
          "status" => if(id == "old", do: "succeeded", else: "running"),
          "repo_path" => ctx.repo,
          "worktree" => %{
            "path" => path,
            "branch" => "loop/s1",
            "base" => "master",
            "status" => wt_status
          }
        })
      )
    end

    RunState.take_ownership(ctx.runs, Path.join(ctx.runs, "new"), path)

    assert {:ok, %{"worktree" => %{"status" => "handed_off"}}} =
             RunState.read(Path.join(ctx.runs, "old"))

    assert Reaper.reap(ctx.runs, 500) == []
    assert File.dir?(path)
  end

  test "a crashed in-flight run whose worktree was handed off leaves that worktree alone", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    run_dir = Path.join(ctx.runs, "superseded")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "superseded",
      run_seq: 0,
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "handed_off"}
    })

    assert [%{worktree: "none recorded or handed off"}] = Reaper.reap(ctx.runs, 500)
    assert File.dir?(path)
  end

  test "a removal git keeps refusing is abandoned after three attempts", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    git!(ctx.repo, ["worktree", "lock", path])
    on_exit(fn -> git!(ctx.repo, ["worktree", "unlock", path]) end)
    run_dir = Path.join(ctx.runs, "locked")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "locked",
      run_seq: 0,
      status: "succeeded",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "remove_failed"}
    })

    for _ <- 1..3, do: assert([_] = Reaper.reap(ctx.runs, 500))

    assert {:ok, %{"worktree" => %{"status" => "remove_abandoned", "removal_attempts" => 3}}} =
             RunState.read(run_dir)

    assert Reaper.reap(ctx.runs, 500) == []
  end

  test "a clean worktree a live run holds the lock for is not removed by another reap", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    :ok = WorktreeLock.acquire(ctx.runs, path, "adopter")
    run_dir = Path.join(ctx.runs, "stale-entry")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "stale-entry",
      run_seq: 0,
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "creating"}
    })

    assert [%{worktree: "held by live run adopter; not touched"}] = Reaper.reap(ctx.runs, 500)
    assert File.dir?(path)
  end

  test "a dead run whose pid a different process now holds is still reaped", ctx do
    run_dir = Path.join(ctx.runs, "reused-pid")
    File.mkdir_p!(run_dir)
    # This BEAM's pid, but a start time that is not this BEAM's: a recycled pid.
    owner = Map.put(Owner.current(), "beam_started", "Thu Jan  1 00:00:00 1970")
    RunState.update(run_dir, Map.merge(owner, %{"run_id" => "reused-pid", "status" => "running"}))

    assert [%{run_id: "reused-pid"}] = Reaper.reap(ctx.runs, 500)
  end

  test "runs owned by a live BEAM, or already finished, are left alone", ctx do
    for {id, status, owner} <- [
          {"live", "running", Owner.current()},
          {"done", "succeeded", %{"beam_os_pid" => dead_pid()}}
        ] do
      dir = Path.join(ctx.runs, id)
      File.mkdir_p!(dir)
      RunState.update(dir, Map.merge(owner, %{"run_id" => id, "status" => status}))
    end

    assert Reaper.reap(ctx.runs, 500) == []
  end
end
