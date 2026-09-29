defmodule LoopctlRunner.ReaperTest do
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    GitGrant,
    Owner,
    ProcessGroup,
    Reaper,
    RunState,
    Session,
    Trace,
    Worktree,
    WorktreeLock
  }

  alias Mix.Tasks.Loopctl.Reap

  import ExUnit.CaptureIO
  import LoopctlRunner.TestSupport

  @moduletag timeout: 30_000

  setup do
    root = tmp_dir!("reaper")
    repo = git_repo!(Path.join(root, "repo"))
    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}])
    on_exit(restore)
    # Every reap in this file sweeps a grant directory THIS TEST OWNS: `Reaper.reap/3` has no
    # default, so none can reach the operator's ~/.claude.
    {:ok,
     root: root,
     repo: repo,
     state: state,
     runs: Path.join(root, "runs"),
     grants: tmp_dir!("reaper-grants")}
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
    LOOP_SESSION_ID=#{session_id} LOOP_TREE_POLL_S=1 #{Session.launcher_script()} #{state}/stderr.log #{headless_launcher()} -p x < #{fifo} >/dev/null 2>&1 &
    """

    {_, 0} = System.cmd("/bin/sh", ["-c", script])
    holder = Path.join(state, "holder_pid")
    on_exit(fn -> System.cmd("kill", ["-KILL", holder |> File.read!() |> String.trim()]) end)
    :ok = wait_until(fn -> File.exists?(Path.join(state, "detached_pid")) end)
    detached = read_int!(Path.join(state, "detached_pid"))
    :ok = wait_until(fn -> recorded?(Path.join(state, "stderr.log.tree"), detached) end)
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
      tree_file: Path.join(ctx.state, "stderr.log.tree"),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "creating"}
    })

    assert [%{run_id: "s1-run", process_group: ":terminated"}] =
             Reaper.reap(ctx.runs, 2_000, ctx.grants)

    refute ProcessGroup.alive?(pgid)
    refute os_pid_alive?(read_int!(Path.join(ctx.state, "grandchild_pid")))
    refute os_pid_alive?(read_int!(Path.join(ctx.state, "detached_pid")))
    assert ProcessGroup.recorded(Path.join(ctx.state, "stderr.log.tree")) == []
    refute File.dir?(path)
    assert {:ok, %{"status" => "reaped"}} = RunState.read(run_dir)

    {:ok, events} = Trace.read(Path.join(run_dir, "trace.ndjson"))
    run_event_id = Integer.to_string(run_seq)
    assert [_, %{"type" => "run.reaped", "parent" => ^run_event_id}] = events
    assert {:ok, _} = Trace.tree(events)

    # Reaping is idempotent: a reaped run is not revisited.
    assert Reaper.reap(ctx.runs, 2_000, ctx.grants) == []
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

    assert [%{process_group: group}] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert group =~ "not signalled"
    assert os_pid_alive?(stranger)
    System.cmd("kill", ["#{stranger}"])
  end

  test "a launcher's group is judged by its recorded kernel start before the legacy one (#66)",
       ctx do
    pgid = orphan_launcher!(ctx.state, Session.uuid4())
    run_dir = Path.join(ctx.runs, "id-leader")
    File.mkdir_p!(run_dir)

    # No marker and no tree file: only the group itself could be signalled. The legacy start
    # says the leader is ours; the kernel-form one, which this runner records and decides by,
    # says not.
    RunState.update(run_dir, %{
      run_id: "id-leader",
      run_seq: 0,
      status: "running",
      beam_os_pid: dead_pid(),
      pgid: pgid,
      leader_start: LoopctlRunner.Owner.local_start_time(pgid),
      leader_start_id: LoopctlRunner.Owner.start_id(pgid) <> "0"
    })

    assert [%{process_group: group}] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert group =~ "not signalled"
    assert ProcessGroup.alive?(pgid)
    System.cmd("kill", ["-KILL", "--", "-#{pgid}"])
    System.cmd("kill", ["-KILL", "#{read_int!(Path.join(ctx.state, "detached_pid"))}"])
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
      session_id: session_id,
      tree_file: Path.join(ctx.state, "stderr.log.tree")
    })

    assert [%{process_group: ":terminated"}] = Reaper.reap(ctx.runs, 2_000, ctx.grants)
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

        assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
        assert worktree =~ "kept"
        assert File.dir?(path)
        assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(run_dir)

        assert {:ok, %{reused: true}} = Worktree.create(ctx.repo, path, "loop/s1", "master")
      end
    end
  end

  test "an orphaned SCRATCH worktree is removed whatever it holds, under the lock", ctx do
    # Scratch, as TriageRun's own teardown treats it — decided by the entry, not by the run's
    # kind, which this state deliberately does not carry. Kept for what it holds, it stays for
    # ever: the run is left `reaped`, and orphan?/1 never looks at a reaped run again.
    tree = Worktree.triage_tree_path(ctx.runs, ctx.repo)
    {:ok, sha} = Worktree.create_detached(ctx.repo, tree)
    File.write!(Path.join(tree, "notes.txt"), "uncommitted")
    run_dir = Path.join(ctx.runs, "triage-orphan")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "triage-orphan",
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: tree, branch: "", base: sha, status: "created", scratch: true}
    })

    assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert worktree =~ ":removed"
    refute File.dir?(tree)
    assert {:ok, %{"worktree" => %{"status" => "removed"}}} = RunState.read(run_dir)
    # The lock the reaper took for the removal is given back: the next triage run takes the tree.
    assert :ok = WorktreeLock.acquire(ctx.runs, tree, "next-run", owner!())
  end

  test "an orphan whose lock will not read is reaped: a corrupt lock protects no one", ctx do
    # Read as held, it named no run and no run could ever release it, so the orphan's tree stayed
    # for ever and every reap reported it held by "unknown".
    tree = Worktree.triage_tree_path(ctx.runs, ctx.repo)
    {:ok, sha} = Worktree.create_detached(ctx.repo, tree)
    :ok = WorktreeLock.acquire(ctx.runs, tree, "a-run-whose-lock-was-truncated", owner!())
    [lock] = Path.wildcard(Path.join([ctx.runs, "locks", "*.lock"]))
    File.write!(lock, "{\"run_id\":")
    run_dir = Path.join(ctx.runs, "triage-orphan")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "triage-orphan",
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: tree, branch: "", base: sha, status: "created", scratch: true}
    })

    assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert worktree =~ ":removed"
    refute File.dir?(tree)
    assert WorktreeLock.live_holder(ctx.runs, tree) == nil
  end

  test "a triage tree RELEASED to the next run, or never prepared, is not the run's to remove",
       ctx do
    # A released entry names the repo's reused tree, which the next run refreshes; a not_prepared
    # one names the path a run could not prepare — the reused tree another run owns, or whatever
    # was in the way. Neither is that run's, so the tree they both name must survive the reap.
    tree = Worktree.triage_tree_path(ctx.runs, ctx.repo)
    {:ok, sha} = Worktree.create_detached(ctx.repo, tree)

    for {name, status} <- [{"released", "released"}, {"never", "not_prepared"}] do
      run_dir = Path.join(ctx.runs, name)
      File.mkdir_p!(run_dir)

      RunState.update(run_dir, %{
        run_id: name,
        status: "running",
        beam_os_pid: dead_pid(),
        repo_path: ctx.repo,
        worktree: %{path: tree, branch: "", base: sha, status: status, scratch: true}
      })
    end

    assert [_, _] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert File.dir?(tree)
  end

  test "a lock the reaper cannot take is logged and that orphan skipped, never raised", ctx do
    # The reaper runs at the start of an implement run. A lock directory that will not be made — a
    # FILE where it goes, standing in for a full or read-only volume — used to raise out of
    # `WorktreeLock.acquire/4` and take that run down with it.
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    run_dir = Path.join(ctx.runs, "orphan")
    File.mkdir_p!(run_dir)
    File.write!(Path.join(ctx.runs, "locks"), "not a directory")

    RunState.update(run_dir, %{
      run_id: "orphan",
      status: "succeeded",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "remove_failed"}
    })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
        assert worktree =~ "lock"
      end)

    assert log =~ "could not take the lock for #{path}"
    assert File.dir?(path)

    # Counted as a failed attempt, so it is tried again rather than forgotten.
    assert {:ok, %{"worktree" => %{"status" => "remove_failed", "removal_attempts" => 1}}} =
             RunState.read(run_dir)
  end

  test "a reaper whose own start cannot be read takes no lock, removes nothing, spends nothing",
       ctx do
    # The lock the reaper holds for a removal records THIS BEAM as its owner. Written without a
    # start it reads dead to every check, so a live run could take the tree over mid-removal: the
    # removal is not attempted. Nothing about the ORPHAN failed, so none of its three attempts is
    # spent — counted, three such reaps abandoned a tree no removal was ever tried on.
    tree = Worktree.triage_tree_path(ctx.runs, ctx.repo)
    {:ok, sha} = Worktree.create_detached(ctx.repo, tree)
    run_dir = Path.join(ctx.runs, "triage-orphan")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "triage-orphan",
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: tree, branch: "", base: sha, status: "created", scratch: true}
    })

    for _reap <- 1..3 do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [%{worktree: worktree}] =
                   Reaper.reap(ctx.runs, 500, ctx.grants, owner: {:error, :no_start})

          assert worktree =~ "own start time could not be read"
        end)

      assert log =~ "the reaper takes no lock for #{tree}; not touched"
      assert File.dir?(tree)
      assert Path.wildcard(Path.join([ctx.runs, "locks", "*.lock"])) == []

      # Left to be revisited, its attempts as they were.
      assert {:ok, %{"worktree" => %{"status" => "remove_failed"} = entry}} =
               RunState.read(run_dir)

      assert Map.get(entry, "removal_attempts", 0) == 0
    end

    # The same orphan, with the start readable: removed under the lock, which is given back.
    assert [%{worktree: removed}] = Reaper.reap(ctx.runs, 500, ctx.grants, owner: {:ok, owner!()})
    assert removed =~ ":removed"
    refute File.dir?(tree)
    assert WorktreeLock.live_holder(ctx.runs, tree) == nil
  end

  test "one reap fetches each repo's base once, however many of its orphans need it", ctx do
    # Two crashed runs whose branches origin already carries by content: each removal asks origin,
    # and asked separately that was one bounded network call per orphan, in series.
    origin = Path.join(ctx.root, "origin.git")
    git!(ctx.root, ["clone", "-q", "--bare", ctx.repo, origin])
    git!(ctx.repo, ["remote", "add", "origin", origin])
    count = Path.join(ctx.root, "fetches")
    upload_pack = Path.join(ctx.root, "upload-pack")
    File.write!(upload_pack, "#!/bin/sh\necho fetch >> #{count}\nexec git upload-pack \"$@\"\n")
    File.chmod!(upload_pack, 0o755)
    git!(ctx.repo, ["config", "remote.origin.uploadpack", upload_pack])

    paths =
      for id <- ~w(s1 s2) do
        path = Worktree.path_for(ctx.repo, id)
        {:ok, _} = Worktree.create(ctx.repo, path, "loop/" <> id, "master")
        File.write!(Path.join(path, id <> ".txt"), id)
        git!(path, ["add", id <> ".txt"])
        git!(path, ["commit", "-q", "-m", id])
        run_dir = Path.join(ctx.runs, id)
        File.mkdir_p!(run_dir)

        RunState.update(run_dir, %{
          run_id: id,
          status: "running",
          beam_os_pid: dead_pid(),
          repo_path: ctx.repo,
          worktree: %{path: path, branch: "loop/" <> id, base: "master", status: "created"}
        })

        path
      end

    # What squash-merging both PRs leaves on origin: one commit carrying both branches' content.
    tree = git!(ctx.repo, ["merge-tree", "--write-tree", "loop/s1", "loop/s2"])
    squash = git!(ctx.repo, ["commit-tree", tree, "-p", "master", "-m", "squash"])
    git!(ctx.repo, ["push", "-q", "origin", squash <> ":refs/heads/master"])
    File.rm(count)

    assert [_, _] = Reaper.reap(ctx.runs, 500, ctx.grants)

    for path <- paths, do: refute(File.dir?(path))
    assert count |> File.read!() |> String.split("\n", trim: true) == ["fetch"]
  end

  test "the bases of different repos are fetched at the same time, not one after another", ctx do
    # Each origin's upload-pack waits for the OTHER's to start, and fails when it has not within
    # ten seconds: fetched in series the first fetch fails, and its shipped branch is kept.
    rendezvous = Path.join(ctx.root, "rendezvous")
    File.mkdir_p!(rendezvous)

    paths =
      for id <- ~w(a b) do
        repo = git_repo!(Path.join(ctx.root, "repo-" <> id))
        origin = Path.join(ctx.root, "origin-#{id}.git")
        git!(ctx.root, ["clone", "-q", "--bare", repo, origin])
        git!(repo, ["remote", "add", "origin", origin])
        other = if id == "a", do: "b", else: "a"
        upload_pack = Path.join(ctx.root, "upload-pack-" <> id)

        File.write!(upload_pack, """
        #!/bin/sh
        touch #{rendezvous}/#{id}
        i=0
        while [ ! -e #{rendezvous}/#{other} ]; do
          i=$((i + 1)); [ "$i" -gt 100 ] && exit 1; sleep 0.1
        done
        exec git upload-pack "$@"
        """)

        File.chmod!(upload_pack, 0o755)
        path = Worktree.path_for(repo, "s1")
        {:ok, _} = Worktree.create(repo, path, "loop/s1", "master")
        git!(repo, ["config", "remote.origin.uploadpack", upload_pack])
        File.write!(Path.join(path, "work.txt"), id)
        git!(path, ["add", "work.txt"])
        git!(path, ["commit", "-q", "-m", "work"])
        # What a squash merge leaves on origin: one new commit with the branch's content.
        tree = git!(repo, ["rev-parse", "loop/s1^{tree}"])
        squash = git!(repo, ["commit-tree", tree, "-p", "master", "-m", "squash"])
        git!(repo, ["push", "-q", "origin", squash <> ":refs/heads/master"])

        run_dir = Path.join(ctx.runs, id)
        File.mkdir_p!(run_dir)

        RunState.update(run_dir, %{
          run_id: id,
          status: "running",
          beam_os_pid: dead_pid(),
          repo_path: repo,
          worktree: %{path: path, branch: "loop/s1", base: "master", status: "created"}
        })

        path
      end

    assert [_, _] = Reaper.reap(ctx.runs, 500, ctx.grants)
    for path <- paths, do: refute(File.dir?(path))
  end

  test "a reap whose orphans are clean or dirty makes no fetch at all", ctx do
    # Neither asks origin: a clean tree is removed and a dirty one kept without comparing
    # content. Fetching anyway cost up to thirty seconds per repo before every run, offline.
    origin = Path.join(ctx.root, "origin.git")
    git!(ctx.root, ["clone", "-q", "--bare", ctx.repo, origin])
    git!(ctx.repo, ["remote", "add", "origin", origin])
    count = Path.join(ctx.root, "fetches")
    upload_pack = Path.join(ctx.root, "upload-pack")
    File.write!(upload_pack, "#!/bin/sh\necho fetch >> #{count}\nexec git upload-pack \"$@\"\n")
    File.chmod!(upload_pack, 0o755)
    git!(ctx.repo, ["config", "remote.origin.uploadpack", upload_pack])

    for id <- ~w(clean dirty) do
      path = Worktree.path_for(ctx.repo, id)
      {:ok, _} = Worktree.create(ctx.repo, path, "loop/" <> id, "master")
      if id == "dirty", do: File.write!(Path.join(path, "wip.txt"), "uncommitted")
      run_dir = Path.join(ctx.runs, id)
      File.mkdir_p!(run_dir)

      RunState.update(run_dir, %{
        run_id: id,
        status: "running",
        beam_os_pid: dead_pid(),
        repo_path: ctx.repo,
        worktree: %{path: path, branch: "loop/" <> id, base: "master", status: "created"}
      })
    end

    File.rm(count)

    assert [_, _] = Reaper.reap(ctx.runs, 500, ctx.grants)

    refute File.dir?(Worktree.path_for(ctx.repo, "clean"))
    assert File.dir?(Worktree.path_for(ctx.repo, "dirty"))
    refute File.exists?(count)
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

    assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
    assert worktree =~ ":removed"
    refute File.dir?(path)

    assert {:ok, %{"status" => "succeeded", "worktree" => %{"status" => "removed"}}} =
             RunState.read(run_dir)

    assert Reaper.reap(ctx.runs, 500, ctx.grants) == []
  end

  test "an entry handed off to a later run is never acted on", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")

    for {id, wt_status} <- [{"old", "remove_failed"}, {"new", "creating"}] do
      dir = Path.join(ctx.runs, id)
      File.mkdir_p!(dir)

      owner = if id == "old", do: %{"beam_os_pid" => dead_pid()}, else: owner!()

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

    assert Reaper.reap(ctx.runs, 500, ctx.grants) == []
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

    assert [%{worktree: "none recorded or handed off"}] = Reaper.reap(ctx.runs, 500, ctx.grants)
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

    for _ <- 1..3, do: assert([_] = Reaper.reap(ctx.runs, 500, ctx.grants))

    assert {:ok, %{"worktree" => %{"status" => "remove_abandoned", "removal_attempts" => 3}}} =
             RunState.read(run_dir)

    assert Reaper.reap(ctx.runs, 500, ctx.grants) == []
  end

  test "a clean worktree a live run holds the lock for is not removed by another reap", ctx do
    path = Worktree.path_for(ctx.repo, "s1")
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    :ok = WorktreeLock.acquire(ctx.runs, path, "adopter", owner!())
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

    assert [%{worktree: "held by live run adopter; not touched"}] =
             Reaper.reap(ctx.runs, 500, ctx.grants)

    assert File.dir?(path)
  end

  describe "a tree that changes while origin is fetched" do
    # The plan reads each tree before the fetch, which can take thirty seconds. Each origin's
    # upload-pack below does something to the tree while that fetch is running.
    test "is not removed once a live run has locked it", ctx do
      path = Worktree.path_for(ctx.repo, "s1")
      :ok = WorktreeLock.acquire(ctx.runs, path, "adopter", owner!())
      [lock] = Path.wildcard(Path.join([ctx.runs, "locks", "*.lock"]))
      File.rename!(lock, lock <> ".saved")
      shipped_orphan!(ctx, path, "cp #{lock}.saved #{lock}")

      assert [%{worktree: "held by live run adopter; not touched"}] =
               Reaper.reap(ctx.runs, 500, ctx.grants)

      assert File.dir?(path)
    end

    test "is removed when only the fetch changed what it reads as holding", ctx do
      # Origin's base reaches the branch by history, which this repository learns only from the
      # fetch: before it the branch holds a commit, after it nothing. Comparing those two answers
      # read the fetch as the tree changing, and kept the branch.
      origin = Path.join(ctx.root, "origin.git")
      git!(ctx.root, ["clone", "-q", "--bare", ctx.repo, origin])
      git!(ctx.repo, ["remote", "add", "origin", origin])
      path = Worktree.path_for(ctx.repo, "s1")
      {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
      File.write!(Path.join(path, "work.txt"), "work")
      git!(path, ["add", "work.txt"])
      git!(path, ["commit", "-q", "-m", "work"])
      # A fast-forward merge on origin that this repository has not fetched.
      git!(origin, ["fetch", "-q", ctx.repo, "loop/s1:master"])
      run_dir = Path.join(ctx.runs, "crashed")
      File.mkdir_p!(run_dir)

      RunState.update(run_dir, %{
        run_id: "crashed",
        status: "running",
        beam_os_pid: dead_pid(),
        repo_path: ctx.repo,
        worktree: %{path: path, branch: "loop/s1", base: "master", status: "created"}
      })

      assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
      assert worktree =~ ":removed"
      refute File.dir?(path)
      assert git!(ctx.repo, ["branch", "--list", "loop/s1"]) == ""
    end

    test "is kept when it gained uncommitted work", ctx do
      path = Worktree.path_for(ctx.repo, "s1")
      run_dir = shipped_orphan!(ctx, path, "echo wip > #{path}/wip.txt")

      assert [%{worktree: worktree}] = Reaper.reap(ctx.runs, 500, ctx.grants)
      assert worktree =~ "changed while origin was fetched"
      assert File.read!(Path.join(path, "wip.txt")) == "wip\n"
      assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(run_dir)
    end
  end

  # A crashed run whose one commit origin's base carries by a squash merge, so the reap asks origin,
  # and origin's upload-pack runs `during_fetch` before serving. Returns the run's directory.
  defp shipped_orphan!(ctx, path, during_fetch) do
    origin = Path.join(ctx.root, "origin.git")
    git!(ctx.root, ["clone", "-q", "--bare", ctx.repo, origin])
    git!(ctx.repo, ["remote", "add", "origin", origin])
    {:ok, _} = Worktree.create(ctx.repo, path, "loop/s1", "master")
    File.write!(Path.join(path, "work.txt"), "work")
    git!(path, ["add", "work.txt"])
    git!(path, ["commit", "-q", "-m", "work"])
    tree = git!(ctx.repo, ["rev-parse", "loop/s1^{tree}"])
    squash = git!(ctx.repo, ["commit-tree", tree, "-p", "master", "-m", "squash"])
    git!(ctx.repo, ["push", "-q", "origin", squash <> ":refs/heads/master"])

    upload_pack = Path.join(ctx.root, "upload-pack")
    File.write!(upload_pack, "#!/bin/sh\n#{during_fetch}\nexec git upload-pack \"$@\"\n")
    File.chmod!(upload_pack, 0o755)
    git!(ctx.repo, ["config", "remote.origin.uploadpack", upload_pack])

    run_dir = Path.join(ctx.runs, "crashed")
    File.mkdir_p!(run_dir)

    RunState.update(run_dir, %{
      run_id: "crashed",
      status: "running",
      beam_os_pid: dead_pid(),
      repo_path: ctx.repo,
      worktree: %{path: path, branch: "loop/s1", base: "master", status: "created"}
    })

    run_dir
  end

  test "a dead run whose pid a different process now holds is still reaped", ctx do
    run_dir = Path.join(ctx.runs, "reused-pid")
    File.mkdir_p!(run_dir)
    # This BEAM's pid, but a start time that is not this BEAM's: a recycled pid.
    owner = Map.update!(owner!(), "beam_start_id", &other_start/1)
    RunState.update(run_dir, Map.merge(owner, %{"run_id" => "reused-pid", "status" => "running"}))

    assert [%{run_id: "reused-pid"}] = Reaper.reap(ctx.runs, 500, ctx.grants)
  end

  test "runs owned by a live BEAM, or already finished, are left alone", ctx do
    for {id, status, owner} <- [
          {"live", "running", owner!()},
          {"done", "succeeded", %{"beam_os_pid" => dead_pid()}}
        ] do
      dir = Path.join(ctx.runs, id)
      File.mkdir_p!(dir)
      RunState.update(dir, Map.merge(owner, %{"run_id" => id, "status" => status}))
    end

    assert Reaper.reap(ctx.runs, 500, ctx.grants) == []
  end

  test "the grant sweep removes only a grant whose owner BEAM is gone", ctx do
    # Teardown only runs on the happy path — the reason this module exists — so a halt or a hard
    # kill leaks a grant. But every Run reaps, and so
    # does `mix loopctl.reap`, beside a daemon whose sessions are live: a grant whose owner is still
    # running is a dispatch in flight, and removing it makes the hook refuse its subagent's
    # commits mid-run.
    %{"beam_os_pid" => me, "beam_start_id" => started} = owner!()

    # A pid that has exited, read off a Port that ran to completion.
    port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    {:os_pid, gone} = Port.info(port, :os_pid)
    assert_receive {^port, {:exit_status, 0}}, 5_000

    grant = &Path.join(ctx.grants, ".subagent-git-grant-" <> &1)
    stamp = &"loopctl-runner session #{&1} owner #{&2} #{&3}\n"

    File.write!(grant.("dead"), stamp.("dead", gone, started))
    # This BEAM's pid under a start time it never had: a reused pid, which is not its owner.
    File.write!(grant.("reused"), stamp.("reused", me, other_start(started)))
    File.write!(grant.("live"), stamp.("live", me, started))
    # A grant a human typed, one stamped but naming no owner, and one another hook overwrote:
    # none names an owner, so none is this sweep's to judge.
    File.write!(grant.("human"), "armed by hand\n")
    File.write!(grant.("legacy"), "loopctl-runner session legacy\n")
    File.write!(grant.("overwritten"), "auto-armed\n")

    # An owner recorded by pid alone is dead even while the pid is held: the pid cannot tell the
    # owner from whatever reused it, and a stale "alive" keeps the grant for ever.
    pid_only = &GitGrant.line(&1, Owner.of(&2, nil))
    File.write!(grant.("pid-only-dead"), pid_only.("pid-only-dead", gone))
    File.write!(grant.("pid-only-live"), pid_only.("pid-only-live", me))

    assert GitGrant.holders(grant.("pid-only-dead")) ==
             {Owner.of(gone, nil), nil}

    # Given its session line once the Port opened: a live owner BEAM no longer keeps it on its
    # own — a session whose GenServer was killed outright runs no teardown while the daemon lives.
    live_owner = Owner.of(me, started)
    ended = Owner.of(gone, started)
    File.write!(grant.("session-gone"), GitGrant.line("session-gone", live_owner, ended))

    File.write!(
      grant.("session-live"),
      GitGrant.line("session-live", live_owner, live_owner)
    )

    Reaper.reap(ctx.runs, 2_000, ctx.grants)

    refute File.exists?(grant.("dead"))
    refute File.exists?(grant.("reused"))
    refute File.exists?(grant.("pid-only-dead"))
    refute File.exists?(grant.("pid-only-live"))
    refute File.exists?(grant.("session-gone"))

    for kept <- ~w(live human legacy overwritten session-live) do
      assert File.exists?(grant.(kept)), "the sweep removed the #{kept} grant"
    end
  end

  test "mix loopctl.reap sweeps the CONFIG's grant directory", ctx do
    # The task is the operator asking; the directory is still the config's, which is what the
    # rest of the runner arms into.
    config = Path.join(ctx.root, "runner.json")
    File.write!(config, JSON.encode!(config_map(ctx.root, %{"grant_dir" => ctx.grants})))
    dead = Path.join(ctx.grants, ".subagent-git-grant-dead")
    File.write!(dead, GitGrant.line("dead", Owner.of(dead_pid(), owner!()["beam_start_id"])))

    capture_io(fn -> Reap.run(["--config", config]) end)

    refute File.exists?(dead)
  end

  test "a session is gone unless processes of it outlived TERM and KILL" do
    assert Reaper.verdict({:error, :survived}) == :survived

    for outcome <- [:terminated, :killed, :already_gone],
        do: assert(Reaper.verdict(outcome) == :gone)
  end
end
