defmodule LoopctlRunner.RunTest do
  # Mutates PATH and FAKE_* in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Run, RunState, Story, Trace, WorktreeLock}
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  setup do
    root = tmp_dir!("run")
    git_repo!(Path.join(root, "repo"))
    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    {:ok, root: root, state: state}
  end

  defp run!(root, state, fake_vars, story_overrides \\ %{}, config_overrides \\ %{}) do
    restore = fake_env!(state, fake_vars)

    try do
      config = config!(root, config_overrides)
      {:ok, story} = Story.from_map(story_map(story_overrides), config)
      Run.execute(config, story)
    after
      restore.()
    end
  end

  defp events!(result) do
    {:ok, events} = Trace.read(Path.join(result.run_dir, "trace.ndjson"))
    events
  end

  defp types(events), do: Enum.map(events, & &1["type"])

  test "a story runs claude in the worktree and leaves a reconstructable trace", %{
    root: root,
    state: state
  } do
    # Built at runtime: a key-named variable assigned a string literal reads to a secret
    # scanner as a leaked credential.
    System.put_env("ANTHROPIC_API_KEY", "canary-#{System.unique_integer([:positive])}")

    result =
      try do
        run!(
          root,
          state,
          [{"FAKE_CLAUDE_MODE", "stream"}],
          %{"allowed_tools" => ["Read"], "prompt" => "- do the thing"},
          %{
            "allowed_tools" => ["Read"]
          }
        )
      after
        System.delete_env("ANTHROPIC_API_KEY")
      end

    assert result.status == "succeeded"
    assert result.session.exit_status == 0

    # The session's cwd IS the worktree (design §8). Compared resolved: on macOS the temp
    # dir lives under /var, a symlink to /private/var.
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])
    {real_root, 0} = System.cmd("realpath", [root])
    real_worktree = Path.join([String.trim(real_root), "repo", ".claude/worktrees/loop-s1"])
    assert File.read!(Path.join(state, "cwd")) |> String.trim() == real_worktree

    # Launched through claude-headless.sh, in loop mode, with the key stripped.
    env = File.read!(Path.join(state, "env"))
    refute env =~ ~r/^ANTHROPIC_API_KEY PRESENT$/m
    assert env =~ ~r/^LOOP_MODE=1$/m
    argv = File.read!(Path.join(state, "argv"))
    assert argv =~ "--permission-prompts\nnone\n"
    assert argv =~ "--session-id\n#{result.session.session_id}\n"
    assert argv =~ "--allowedTools\nRead\n"
    assert String.ends_with?(argv, "--\n- do the thing\n")
    refute argv =~ "--bare"

    events = events!(result)
    assert {:ok, [root_node]} = Trace.tree(events)
    assert root_node.event["type"] == "run.started"

    by_type = Enum.group_by(events, & &1["type"])
    [session] = by_type["session.started"]
    [agent_dispatch] = Enum.filter(by_type["claude.tool_use"], &(&1["data"]["name"] == "Agent"))
    [read_use] = Enum.filter(by_type["claude.tool_use"], &(&1["data"]["name"] == "Read"))

    [subagent_msg] =
      Enum.filter(by_type["claude.assistant"], &(&1["parent"] == agent_dispatch["seq"]))

    assert read_use["parent"] == subagent_msg["seq"]
    assert session["parent"] == root_node.event["seq"]
    assert hd(by_type["claude.unparsed"])["parent"] == session["seq"]
    # The last line had no trailing newline and still arrived.
    assert [%{"data" => %{"num_turns" => 2}}] = by_type["claude.result.success"]

    assert ["worktree.created" | _] = types(events) -- ["run.started"]
    assert List.last(types(events)) == "run.finished"
    assert "worktree.removed" in types(events)
    refute File.dir?(worktree)

    assert {:ok, %{"status" => "succeeded", "pgid" => pgid}} = RunState.read(result.run_dir)
    assert pgid == result.session.os_pid
    assert File.read!(Path.join(result.run_dir, "stdout.ndjson")) =~ ~s("type":"result")
  end

  test "git variables inherited from a hook redirect neither the runner nor the session", %{
    root: root,
    state: state
  } do
    # What git exports to a pre-commit hook, pointed somewhere harmful.
    vars = [{"GIT_INDEX_FILE", ".git/index"}, {"GIT_DIR", Path.join(root, "not-a-repo")}]
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    result =
      try do
        run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])
      after
        Enum.each(vars, fn {k, _} -> System.delete_env(k) end)
      end

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))
    refute env =~ ~r/^GIT_(INDEX_FILE|DIR) PRESENT$/m
  end

  test "a non-zero exit fails the run and still tears down", %{root: root, state: state} do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_EXIT", "7"}])
    assert result.status == "failed"
    assert result.session.exit_status == 7
    assert result.teardown.worktree == :removed
  end

  test "the wall-clock budget kills the whole process group, grandchildren included", %{
    root: root,
    state: state
  } do
    result =
      run!(root, state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}], %{
        "wall_clock_s" => 2
      })

    assert result.status == "wall_clock_exceeded"
    refute os_pid_alive?(read_int!(Path.join(state, "grandchild_pid")))
    refute os_pid_alive?(read_int!(Path.join(state, "detached_pid")))
    refute os_pid_alive?(result.session.os_pid)

    types = types(events!(result))
    assert "session.wall_clock_exceeded" in types
    assert "session.terminated" in types
    refute "session.parked" in types
  end

  test "a quiet session the agents probe reports idle is parked and killed", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "idle"}])

    assert result.status == "parked"
    refute os_pid_alive?(read_int!(Path.join(state, "grandchild_pid")))
    refute os_pid_alive?(read_int!(Path.join(state, "detached_pid")))

    events = events!(result)
    [parked] = Enum.filter(events, &(&1["type"] == "session.parked"))
    assert parked["data"]["agent_status"] == "idle"
    assert parked["data"]["stdout_idle_ms"] >= 1000
  end

  test "a quiet session whose probe fails is not parked on silence alone", %{
    root: root,
    state: state
  } do
    result =
      run!(root, state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "fail"}], %{
        "wall_clock_s" => 4
      })

    assert result.status == "wall_clock_exceeded"
    liveness = Enum.filter(events!(result), &(&1["type"] == "session.liveness"))
    assert liveness != []
    assert Enum.all?(liveness, &(&1["data"]["verdict"] == "quiet"))
  end

  test "children the CLI leaves behind are killed when it exits, detached ones included", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "exit_leaving_child"}])

    assert result.status == "succeeded"
    refute os_pid_alive?(read_int!(Path.join(state, "grandchild_pid")))
    refute os_pid_alive?(read_int!(Path.join(state, "detached_pid")))
  end

  test "a session that finishes while the agents probe runs is not recorded as parked", %{
    root: root,
    state: state
  } do
    result =
      run!(root, state, [
        {"FAKE_CLAUDE_MODE", "quiet_then_result"},
        {"FAKE_AGENTS", "slow_absent"}
      ])

    assert result.status == "succeeded"
    assert result.session.reason == :exited
    refute "session.parked" in types(events!(result))
  end

  test "a probe that times out does not crash the session monitor", %{root: root, state: state} do
    result =
      run!(
        root,
        state,
        [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "hang"}],
        %{"wall_clock_s" => 5},
        %{
          "agents_probe_timeout_s" => 1
        }
      )

    assert result.status == "wall_clock_exceeded"
    assert Enum.any?(events!(result), &(&1["type"] == "session.liveness"))
  end

  test "a session that cannot start still tears down and closes the run", %{
    root: root,
    state: state
  } do
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "stream"}])

    result =
      try do
        config = config!(root)
        {:ok, story} = Story.from_map(story_map(), config)
        # An env name git or the OS would never accept makes Port.open raise inside init.
        Run.execute(config, story, env: [{"NOT=VALID", "x"}])
      after
        restore.()
      end

    assert result.status == "crashed"
    assert result.error =~ "session_start_failed"
    assert result.teardown.worktree == :removed

    assert {:ok, %{"status" => "crashed", "worktree" => %{"status" => "removed"}}} =
             RunState.read(result.run_dir)

    assert List.last(types(events!(result))) == "run.finished"
  end

  test "a worktree teardown could not remove is recorded as remove_failed, not removed", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "lock_worktree"}])

    assert result.status == "succeeded"
    assert {:error, _} = result.teardown.worktree
    assert {:ok, %{"worktree" => %{"status" => "remove_failed"}}} = RunState.read(result.run_dir)
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])
    git!(Path.join(root, "repo"), ["worktree", "unlock", worktree])
  end

  test "teardown keeps a worktree holding uncommitted work instead of force-removing it", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "write_file"}])

    assert result.status == "succeeded"
    assert {:kept, "uncommitted changes"} = result.teardown.worktree
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])
    assert File.read!(Path.join(worktree, "wip.txt")) == "draft\n"
    assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(result.run_dir)
    assert "worktree.kept" in types(events!(result))
  end

  test "a re-run adopting a worktree takes it over in the registry", %{root: root, state: state} do
    first = run!(root, state, [{"FAKE_CLAUDE_MODE", "write_file"}])
    assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(first.run_dir)

    second = run!(root, state, [{"FAKE_CLAUDE_MODE", "write_file"}])

    assert [%{"data" => %{"reused" => true}}] =
             Enum.filter(events!(second), &(&1["type"] == "worktree.created"))

    assert {:ok, %{"worktree" => %{"status" => "handed_off"}}} = RunState.read(first.run_dir)
    assert {:ok, %{"worktree" => %{"status" => "kept"}}} = RunState.read(second.run_dir)
  end

  test "a worktree held by a live in-flight run is refused, not adopted", %{
    root: root,
    state: state
  } do
    config = config!(root)
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])
    :ok = WorktreeLock.acquire(config.runs_dir, worktree, "holder")

    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])
    assert result.status == "failed"
    assert result.error =~ "in use by live run holder"
    refute File.exists?(Path.join(state, "session_id"))
  end

  test "two runs of one story started together never share the worktree", %{
    root: root,
    state: state
  } do
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}])

    results =
      try do
        config = config!(root)
        {:ok, story} = Story.from_map(story_map(%{"wall_clock_s" => 3}), config)

        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Run.execute(config, story) end) end)
        |> Enum.map(&Task.await(&1, 30_000))
      after
        restore.()
      end

    assert results |> Enum.map(& &1.status) |> Enum.sort() == ["failed", "wall_clock_exceeded"]
    assert Enum.find(results, &(&1.status == "failed")).error =~ "in use by live run"
  end

  test "a raise inside a run frees the worktree lock", %{root: root, state: state} do
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "delete_run_dir"}])
    config = config!(root)
    {:ok, story} = Story.from_map(story_map(), config)
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])

    try do
      assert_raise File.Error, fn -> Run.execute(config, story) end
    after
      restore.()
    end

    assert WorktreeLock.live_holder(config.runs_dir, worktree) == nil
    assert :ok = WorktreeLock.acquire(config.runs_dir, worktree, "next")
  end

  test "a detached child that ignores TERM is killed by the runner's escalation", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "exit_leaving_stubborn_child"}])

    assert result.status == "succeeded"
    stubborn = read_int!(Path.join(state, "stubborn_pid"))
    refute os_pid_alive?(stubborn)

    assert [%{"data" => %{"stragglers" => ":killed"}}] =
             Enum.filter(events!(result), &(&1["type"] == "session.exited"))
  end

  test "a worktree failure is recorded and nothing is started", %{root: root, state: state} do
    git!(Path.join(root, "repo"), ["branch", "loop/s1"])
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert result.status == "failed"
    assert result.error =~ "already exists without a worktree"
    refute File.exists?(Path.join(state, "session_id"))
    assert "worktree.failed" in types(events!(result))
  end
end
