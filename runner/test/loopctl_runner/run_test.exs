defmodule LoopctlRunner.RunTest do
  # Mutates PATH and FAKE_* in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{GitGrant, Owner, Run, RunState, Session, Story, Trace, WorktreeLock}
  import ExUnit.CaptureLog
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

  # Sets `vars` for the duration of `fun` and puts back WHAT WAS THERE, which is not the same as
  # deleting them afterwards. SSH_AUTH_SOCK, GPG_AGENT_INFO and ANTHROPIC_API_KEY are all live in
  # the shell that runs `mix test`, so a `System.delete_env/1` teardown removes the operator's
  # real value from this BEAM for every test that runs after it — silently, and only on a machine
  # where the variable was set.
  defp with_env(vars, fun) do
    saved = Enum.map(vars, fn {name, _} -> {name, System.get_env(name)} end)
    # A nil value means UNSET for the duration — the only way a test can control what
    # `System.get_env/0` holds on a machine whose own environment carries shaped names.
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "with_env/2 restores what was there, which deleting afterwards does not" do
    # The teardown this replaces was `System.delete_env/1`, which is correct only for a name that
    # was unset to begin with. SSH_AUTH_SOCK, GPG_AGENT_INFO and ANTHROPIC_API_KEY are live in the
    # shell that runs `mix test`, so the old shape removed the operator's real values from this
    # BEAM for every test that ran afterwards. Placeholders below are this test's own, not read
    # from the environment.
    name = "RUN_TEST_RESTORE_PROBE"
    System.put_env(name, "was-here")

    with_env([{name, "during"}], fn -> assert System.get_env(name) == "during" end)
    assert System.get_env(name) == "was-here"

    System.delete_env(name)
    with_env([{name, "during"}], fn -> assert System.get_env(name) == "during" end)
    refute System.get_env(name)
  end

  test "a repo's session_env reaches its session, with {run} and {story} rendered", %{
    root: root,
    state: state
  } do
    result =
      run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
        "session_env" => %{
          "fixture" => %{"RUNNER_ENV_PROBE" => "fixture_loop_{run}_{story}_test"}
        }
      })

    assert result.status == "succeeded"
    short = binary_part(result.run_id, 0, 8)
    story = :sha256 |> :crypto.hash("s1") |> Base.encode16(case: :lower) |> binary_part(0, 8)

    assert File.read!(Path.join(state, "env")) =~
             ~r/^RUNNER_ENV_PROBE=fixture_loop_#{short}_#{story}_test$/m
  end

  test "a story runs claude in the worktree and leaves a reconstructable trace", %{
    root: root,
    state: state
  } do
    # Built at runtime: a key-named variable assigned a string literal reads to a secret
    # scanner as a leaked credential.
    release_root = Path.join(root, "loopctl-release-canary")

    # What a mix release boots with: a session must inherit none of it.
    vars = [
      {"ANTHROPIC_API_KEY", "canary-#{System.unique_integer([:positive])}"},
      {"RELEASE_ROOT", release_root},
      {"RELEASE_COOKIE", "canary-#{System.unique_integer([:positive])}"},
      {"EMU", "beam"},
      {"PATH", Path.join(release_root, "erts-0/bin") <> ":" <> System.get_env("PATH")}
    ]

    result =
      with_env(vars, fn ->
        run!(
          root,
          state,
          [{"FAKE_CLAUDE_MODE", "stream"}],
          %{"allowed_tools" => ["Edit(./lib/**)"], "prompt" => "- do the thing"},
          %{
            "allowed_tools" => ["Edit(./lib/**)"]
          }
        )
      end)

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
    refute env =~ ~r/^(RELEASE_ROOT|RELEASE_COOKIE|EMU|RELEASE_PATH) PRESENT$/m
    assert env =~ ~r/^LOOP_MODE=1$/m
    argv = File.read!(Path.join(state, "argv"))
    # Only what is pre-allowed runs, under no operator or repository settings.
    assert argv =~ "--permission-mode\ndontAsk\n"
    assert argv =~ "--permission-prompts\nnone\n"
    assert argv =~ "--setting-sources\n\n"
    refute argv =~ "\nauto\n"

    for rule <- LoopctlRunner.Session.file_rules() do
      assert argv =~ "--allowedTools\n#{rule}\n"
    end

    # The session's tools are limited, not merely allowed: every restricting flag reaches claude.
    assert argv =~ "--tools\nRead,Edit,Write,Glob,Grep,Bash\n"
    assert argv =~ "--strict-mcp-config\n--mcp-config\n{\"mcpServers\":{}}\n"
    assert argv =~ "--disallowedTools\nmcp__*\n"
    assert argv =~ "--session-id\n#{result.session.session_id}\n"
    assert argv =~ "--allowedTools\nEdit(./lib/**)\n"
    assert argv =~ "--allowedTools\nBash(#{LoopctlRunner.Session.escalate_script()}:*)\n"
    assert argv =~ "--append-system-prompt\n"
    assert argv =~ LoopctlRunner.Session.escalate_script()
    assert File.read!(Path.join(state, "story_file")) == "regular\n"
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
      Enum.filter(by_type["claude.assistant"], &(&1["parent"] == agent_dispatch["event_id"]))

    assert read_use["parent"] == subagent_msg["event_id"]
    assert session["parent"] == root_node.event["event_id"]
    assert hd(by_type["claude.unparsed"])["parent"] == session["event_id"]

    # Every line is a valid contract RunnerTraceEvent, under a UUID run id.
    assert result.run_id =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    assert Enum.all?(events, &(&1["run_id"] == result.run_id))
    assert Enum.all?(events, &(LoopctlRunner.Contract.validate("RunnerTraceEvent", &1) == :ok))
    assert {:ok, %{"run_id" => run_id}} = RunState.read(result.run_dir)
    assert run_id == result.run_id
    # The last line had no trailing newline and still arrived.
    assert [%{"data" => %{"num_turns" => 2}}] = by_type["claude.result.success"]

    assert ["worktree.created" | _] = types(events) -- ["run.started"]
    # The fixture has no origin: the branch is cut from the local base, and the trace says why.
    assert [
             %{
               "data" => %{"start" => "master", "fetch" => "failed", "fetch_error" => fetch_error}
             }
           ] =
             by_type["worktree.created"]

    assert fetch_error =~ "git fetch exited "
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

    result = with_env(vars, fn -> run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}]) end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))
    refute env =~ ~r/^GIT_(INDEX_FILE|DIR) PRESENT$/m
  end

  test "the operator's agent socket and forge tokens reach no session", %{
    root: root,
    state: state
  } do
    # Set HERE, not merely asserted absent: a bare refutation of a name nothing sets would pass
    # with the whole unset list deleted. Some of these ARE in the shell that runs `mix test` and
    # some are not, which is exactly why they are set rather than assumed either way — and why
    # `with_env/2` puts the real values back instead of deleting them. Values are inert and built
    # at runtime (a token-named variable assigned a literal reads to a secret scanner as a leak);
    # nothing ever asserts on a value, only on whether the NAME arrived.
    nonce = Integer.to_string(System.unique_integer([:positive]))

    vars = [
      # Live in the daemon's environment on a dev machine: an agent holding the operator's
      # GitHub identity, one allow-list entry away from a push as him.
      {"SSH_AUTH_SOCK", "/tmp/not-a-real-agent-socket-" <> nonce},
      {"SSH_AGENT_PID", "0"},
      # The same class, and also live on a dev machine — though only the legacy discovery path:
      # modern GnuPG finds the agent under XDG_RUNTIME_DIR, which stays inherited.
      {"GPG_AGENT_INFO", "/tmp/not-a-real-gpg-socket-" <> nonce <> ":0:1"},
      {"GH_TOKEN", "not-a-real-value-" <> nonce},
      {"GITHUB_TOKEN", "not-a-real-value-" <> nonce},
      # Not a credential but the path to one: the program git and ssh run to obtain a
      # passphrase, which is how an unattended session acquires one with no terminal involved.
      {"GIT_ASKPASS", "/tmp/not-a-real-askpass-" <> nonce},
      {"SSH_ASKPASS", "/tmp/not-a-real-askpass-" <> nonce}
    ]

    result = with_env(vars, fn -> run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}]) end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))

    for {name, _} <- vars do
      refute env =~ ~r/^#{name} PRESENT$/m, "#{name} reached the session"
    end

    # The session still got the environment it is supposed to have: the assertions above are
    # about a subtraction, and would also hold if the launch had never happened.
    assert env =~ ~r/^LOOP_MODE=1$/m
  end

  test "a credential the runner has never heard of is unset by SHAPE", %{root: root, state: state} do
    # The name list is calibrated to the systemd daemon's environment, which carries no
    # credential at all. `mix loopctl.serve` is a daemon too and runs in the operator's LOGIN
    # shell, where 41 names of this shape were counted — none of them on any list, all of them
    # handed to a session with a Bash tool. Inert values, and never asserted on.
    nonce = Integer.to_string(System.unique_integer([:positive]))

    vars =
      Enum.map(
        # The last two are matched by the `_KEY` suffix and infix arms and by nothing else, so
        # dropping that arm has to show up here rather than only in the shape unit test.
        ~w(NPM_TOKEN AWS_SECRET_ACCESS_KEY HEX_API_KEY PGPASSWORD SOME_VENDOR_PRIVATE_KEY
           SIGNING_KEY DEPLOY_KEY_PATH),
        &{&1, "not-a-real-value-" <> nonce}
      )

    result = with_env(vars, fn -> run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}]) end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))

    for {name, _} <- vars do
      refute env =~ ~r/^#{name} PRESENT$/m, "#{name} reached the session"
    end

    assert env =~ ~r/^LOOP_MODE=1$/m
  end

  test "a shaped name in session_env survives, though the same name in the environment does not",
       %{root: root, state: state} do
    # The escape hatch, end to end and against the ordering trap: SANDBOX_API_KEY is in the
    # DAEMON's environment (where the shape deny would unset it) AND in this repo's session_env
    # (where the operator said this repo's session needs it). The sibling test above proves the
    # first half alone loses it, so its arrival here is the configuration and nothing else.
    nonce = Integer.to_string(System.unique_integer([:positive]))
    assert LoopctlRunner.Session.credential_shaped?("SANDBOX_API_KEY")

    result =
      with_env([{"SANDBOX_API_KEY", "not-a-real-value-" <> nonce}], fn ->
        run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
          "session_env" => %{"fixture" => %{"SANDBOX_API_KEY" => "from-session-env"}}
        })
      end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))
    # By NAME: the fixture records a credential-shaped variable's presence and never its value,
    # so what is proved here is that the name reached the session. That its VALUE is the
    # configured one rather than the inherited one is the next test, on a name whose value the
    # fixture may record because it is a test probe and not a credential.
    assert env =~ ~r/^SANDBOX_API_KEY PRESENT$/m
  end

  test "a session_env value wins over the same name inherited from the daemon", %{
    root: root,
    state: state
  } do
    # The other half of the ordering question, on RUNNER_ENV_PROBE because the fixture records
    # ITS value: session_env comes after the inherited environment, so the configured value is
    # what a session sees. Without this, the test above could hold while the session still read
    # the daemon's value.
    result =
      with_env([{"RUNNER_ENV_PROBE", "from-the-daemon-environment"}], fn ->
        run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
          "session_env" => %{"fixture" => %{"RUNNER_ENV_PROBE" => "from-session-env"}}
        })
      end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))
    assert env =~ ~r/^RUNNER_ENV_PROBE=from-session-env$/m
    refute env =~ ~r/^RUNNER_ENV_PROBE=from-the-daemon-environment$/m
  end

  test "the shaped names being unset are LOGGED, by name and never by value", %{
    root: root,
    state: state
  } do
    # A silent irreversible subtraction is worse than a loud one even when it is right: without
    # this an operator meets the shape deny as a build failing for no stated reason, with the
    # name they need in no log anywhere. Values never appear — this line is written on every
    # session start, on machines whose environment carries live credentials.
    nonce = Integer.to_string(System.unique_integer([:positive]))
    dropped_value = "not-a-real-value-" <> nonce

    # The suite runs at :warning (test_helper.exs) and this line is deliberately :info — it is
    # written on every session start, and a warning on every routine run trains operators to
    # ignore warnings. Sync tests never run beside async ones, so the level is this test's alone.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log(fn ->
        result =
          with_env([{"NPM_TOKEN", dropped_value}, {"SANDBOX_API_KEY", dropped_value}], fn ->
            run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
              "session_env" => %{"fixture" => %{"SANDBOX_API_KEY" => "from-session-env"}}
            })
          end)

        assert result.status == "succeeded"
      end)

    assert log =~ "NPM_TOKEN"
    assert log =~ "kept by session_env: SANDBOX_API_KEY"
    # It names the way back, or the operator has a mystery instead of a decision.
    assert log =~ "session_env to keep it"
    refute log =~ dropped_value
    refute log =~ "from-session-env"

    # ANTHROPIC_API_KEY is shape-matched AND unconditional, and it is set for this run by the
    # test above it. The advice must never point at a name session_env would refuse: following
    # it produces a config that will not load, which aborts the release preflight.
    assert log =~ "unset unconditionally, with no way to keep them"
    assert Regex.run(~r/unsetting [0-9]+ credential-shaped name\(s\): ([^(]*)/, log)
    [_, advised] = Regex.run(~r/unsetting [0-9]+ credential-shaped name\(s\): ([^(]*)/, log)

    for name <- advised |> String.split(", ") |> Enum.map(&String.trim/1), name != "" do
      assert LoopctlRunner.Config.session_env_allows?(name),
             "the drop log advised session_env for #{name}, which the config would refuse"
    end
  end

  test "the drop log degenerates into nothing when every shaped name is kept", %{
    root: root,
    state: state
  } do
    # Guarded on what was DROPPED, not on what was shaped: otherwise a run where session_env
    # supplies every shaped name present printed "unsetting 0 credential-shaped name(s): " with
    # an empty list and advice to do the thing that had already been done.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    # Deterministic on any machine: this one's own environment carries shaped names, so without
    # clearing them `dropped` is never empty here and the case under test never arises. They are
    # restored by with_env/2, values included.
    cleared =
      Enum.map(
        LoopctlRunner.Session.credential_shaped_env(System.get_env()) -- ["SANDBOX_API_KEY"],
        &{&1, nil}
      )

    log =
      capture_log(fn ->
        result =
          with_env([{"SANDBOX_API_KEY", "not-a-real-value"} | cleared], fn ->
            run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
              "session_env" => %{"fixture" => %{"SANDBOX_API_KEY" => "from-session-env"}}
            })
          end)

        assert result.status == "succeeded"
      end)

    # The line was emitted at all, so the refutations below are about its CONTENT. Without this
    # they would also pass on a run that logged nothing.
    assert log =~ "kept by session_env: SANDBOX_API_KEY"
    refute log =~ "unsetting 0"
    refute log =~ "name(s): ;"
    refute log =~ ~r/name\(s\): \s*(;|\.|$)/m
  end

  test "a git transport override in the runner's environment reaches no session", %{
    root: root,
    state: state
  } do
    # A different class from the credentials above: these name the PROGRAM git executes, so an
    # inherited value runs arbitrary code on every git call a session makes, and a value that
    # merely redirects ssh picks the identity git authenticates with. Set here, not merely
    # refuted, for the same reason as the test above. Inert: /bin/true accepts ssh's arguments
    # and does nothing, and the value is never asserted on.
    vars = [{"GIT_SSH_COMMAND", "/bin/true"}, {"GIT_SSH", "/bin/true"}]

    result = with_env(vars, fn -> run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}]) end)

    assert result.status == "succeeded"
    env = File.read!(Path.join(state, "env"))

    for {name, _} <- vars do
      refute env =~ ~r/^#{name} PRESENT$/m, "#{name} reached the session"
    end

    assert env =~ ~r/^LOOP_MODE=1$/m
  end

  test "characterisation, not a desired property: a deliberate :env value loses to the unset list",
       %{root: root, state: state} do
    # WHAT THIS RECORDS, so a future reader knows it is a trap and not a guarantee: port_env/4
    # appends the unsets AFTER the caller's `:env`, so for a name in both the unset wins and the
    # supplied value never reaches the session. Harmless today — Config refuses every unset name
    # in session_env and nothing else supplies one — and a live hazard for the planned deploy
    # key, which sets GIT_SSH_COMMAND on purpose and would be silently dropped. When that change
    # makes an explicit value win, THIS TEST IS SUPPOSED TO GO RED: invert it, do not delete it.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "stream"}])

    result =
      try do
        config = config!(root)
        {:ok, story} = Story.from_map(story_map(), config)
        Run.execute(config, story, env: [{"GIT_SSH_COMMAND", "/bin/true"}])
      after
        restore.()
      end

    assert result.status == "succeeded"
    refute File.read!(Path.join(state, "env")) =~ ~r/^GIT_SSH_COMMAND PRESENT$/m
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

  test "the subagent git grant is armed for the session and removed at teardown", %{
    root: root,
    state: state
  } do
    # A loop session dispatches an engineer agent to do the implementing (this repo's CLAUDE.md
    # says so), and block-subagent-git.sh — a PreToolUse hook in the operator's user settings,
    # live in any session that loads them — refuses that agent's `git commit` unless the
    # dispatching session armed this file first. The agent's report then
    # reads as having chosen not to commit, so the failure looks like a judgement call: the whole
    # reason this is tested from INSIDE the session rather than inferred.
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert result.status == "succeeded"
    assert File.read!(Path.join(state, "git_grant")) == "GIT_GRANT PRESENT\n"
    # Stamped with THIS BEAM as its owner, which is what keeps a reap beside a live session from
    # sweeping it: an owner that is running is a dispatch in flight.
    assert LoopctlRunner.GitGrant.holders(Path.join(state, "git_grant_stamp")) ==
             {granted(owner!()), nil}

    # ...and it does not outlive the session. An orphan authorises a uuid nothing will hold
    # again, so it is inert rather than dangerous — but an unscoped, un-removed sentinel is the
    # failure KB 7a9afe2e measures, and this is the half that keeps it from becoming one.
    refute File.exists?(LoopctlRunner.GitGrant.path(config!(root), result.session.session_id))
  end

  @tag :capture_log
  test "a grant that cannot be written is never announced to the session", %{
    root: root,
    state: state
  } do
    # LOOP_GIT_GRANT is fixed at the fork. Set before the write that could fail, it told the
    # session of a grant that did not exist; a grant directory under a regular file cannot be.
    blocker = Path.join(root, "not-a-directory")
    File.write!(blocker, "")

    result =
      run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}], %{}, %{
        "grant_dir" => Path.join(blocker, "grants")
      })

    assert result.status == "succeeded"
    assert File.read!(Path.join(state, "git_grant_env")) == "LOOP_GIT_GRANT UNSET\n"
    assert File.read!(Path.join(state, "git_grant")) == "GIT_GRANT ABSENT\n"
  end

  test "a grant whose arm fails after the fork is no grant: the session finds no file", %{
    root: root,
    state: state
  } do
    # LOOP_GIT_GRANT is fixed at the fork, which comes before arming can fail, so it says WHERE the
    # grant is and never that there is one: the hook tests the FILE. A directory where the grant
    # goes fails the rename that would arm it — and leaves no pending file behind either.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "stream"}])
    on_exit(restore)
    session_id = Session.uuid4()
    grant = GitGrant.path(config!(root), session_id)
    File.mkdir_p!(Path.join(grant, "occupied"))

    log =
      capture_log(fn ->
        %{pid: pid} = start_session!(root, session_id)
        assert_receive {:session_result, ^pid, _}, 20_000
      end)

    assert log =~ "could not arm the subagent git grant for session #{session_id}"
    assert File.read!(Path.join(state, "git_grant_env")) == "LOOP_GIT_GRANT SET\n"
    assert File.read!(Path.join(state, "git_grant")) == "GIT_GRANT ABSENT\n"
    assert File.ls!(Path.dirname(grant)) == [Path.basename(grant)]
  end

  test "the run records this BEAM as its owner, start and all", %{root: root, state: state} do
    # A state without its owner's start reads as an orphan, so the next run's reap would kill a
    # live session. The owner is read before anything is written and recorded as read.
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])

    {:ok, recorded} = RunState.read(result.run_dir)
    # Both starts: the one this runner judges by, and the `ps lstart` string a runner built before
    # it judges by — without which that runner's reap kills this run's session.
    assert Map.take(recorded, ["beam_os_pid", "beam_start_id", "beam_started"]) == owner!()
    assert is_binary(recorded["beam_started"])
  end

  test "stopping the Session while its port is LIVE still ends the whole tree", %{
    root: root,
    state: state
  } do
    # The runner-shutdown path, and the one kill path nothing covered: every other test reaches
    # teardown after the CLI has exited, when `port` is already nil, so `terminate/2`'s live-port
    # branch ran in no test at all — mutating `ProcessGroup.terminate/3` out of it left the FULL
    # suite green. It is also the clause that must disarm the subagent git grant on a runner
    # shutdown, and a missed kill is a straggler holding a port.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}])

    on_exit(restore)
    %{pid: pid, grant: grant} = start_session!(root)

    # Wait until the fixture has detached its children, so there is a tree to miss.
    grandchild = Path.join(state, "grandchild_pid")
    detached = Path.join(state, "detached_pid")
    :ok = wait_until(fn -> File.exists?(grandchild) and File.exists?(detached) end, 10_000)
    grandchild = read_int!(grandchild)
    detached = read_int!(detached)
    assert os_pid_alive?(grandchild)
    assert os_pid_alive?(detached)
    assert File.exists?(grant)

    # The port is still open here: this is the clause under test.
    GenServer.stop(pid)

    # Disarmed on this path too: a runner shutdown must not leave the grant behind.
    refute File.exists?(grant)

    refute os_pid_alive?(grandchild)
    # The detached one is in its own session and carries only the marker, which is what
    # ProcessGroup.terminate/3 uses to find it.
    refute os_pid_alive?(detached)
  end

  test "a session's grant is gone BEFORE its waiter hears the result", %{
    root: root,
    state: state
  } do
    # A result in hand has to mean the grant is disarmed: whatever acts on it — the next run's
    # sweep, a shutdown — must not find it still armed. Ordered by trace, because looking at the
    # file once the result arrives races the session's own teardown and passes either way.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "stream"}])
    on_exit(restore)

    %{pid: pid, grant: grant} = start_session!(root)
    ref = Process.monitor(pid)
    trace_session(pid, [{File, :rm, 1}])

    assert_receive {:session_result, ^pid, _}, 20_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert traced_events(pid, fn
             {:trace, _, :call, {File, :rm, [^grant]}} -> :disarmed
             {:trace, _, :send, {:session_result, _, _}, _} -> :result_sent
             _ -> nil
           end) == [:disarmed, :result_sent]

    refute File.exists?(grant)
  end

  test "stopping a live session kills its tree BEFORE disarming its grant", %{
    root: root,
    state: state
  } do
    # Disarmed first, a subagent committing during the kill's grace period has that commit
    # refused by the hook while its session is still running.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}])
    on_exit(restore)

    %{pid: pid, grant: grant} = start_session!(root)
    :ok = wait_until(fn -> File.exists?(Path.join(state, "grandchild_pid")) end, 10_000)
    trace_session(pid, [{File, :rm, 1}, {LoopctlRunner.ProcessGroup, :terminate, 3}])

    GenServer.stop(pid)

    assert pid
           |> traced_events(fn
             {:trace, _, :call, {LoopctlRunner.ProcessGroup, :terminate, _}} -> :killed
             {:trace, _, :call, {File, :rm, [^grant]}} -> :disarmed
             _ -> nil
           end)
           |> Enum.dedup() == [:killed, :disarmed]

    refute File.exists?(grant)
  end

  test "terminate/2 disarms the grant even when ending the tree raises", %{root: root} do
    # This BEAM owns the grant and lives on, so no sweep would remove one a raising kill skipped.
    grant = Path.join(root, "grant")
    File.write!(grant, "armed\n")
    # A live port with no config: reading the kill's grace period raises before any signal.
    state = %{grant: grant, port: :live, os_pid: 1, config: nil}

    assert catch_error(Session.terminate(:shutdown, state))
    refute File.exists?(grant)
  end

  test "a session killed outright leaves a grant the sweep removes once its launcher is gone", %{
    root: root,
    state: state
  } do
    # A Session killed with :kill runs no terminate/2, and the BEAM that owns its grant — the
    # daemon's — lives on, so judged by that owner alone the grant would never be swept. The
    # session line the runner writes once the Port opens names the launcher, which does end.
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}])
    on_exit(restore)

    %{pid: pid, config: config, grant: grant} = start_session!(root)
    :ok = wait_until(fn -> File.exists?(Path.join(state, "grandchild_pid")) end, 10_000)
    %{os_pid: launcher} = :sys.get_state(pid)

    # Armed with its session line in the one write: the launcher, by pid and start.
    assert {owner, %{"beam_os_pid" => ^launcher, "beam_start_id" => started}} =
             GitGrant.holders(grant)

    assert owner == granted(owner!())
    assert started == Owner.of(launcher)["beam_start_id"]
    # From the same reading: the launcher's start in the `ps lstart` form ProcessGroup compares.
    assert {:ok, %{"leader_start" => leader_start}} = RunState.read(Path.join(root, "direct-run"))
    assert leader_start == Owner.start_time(launcher)
    # Its BEAM and its session both running: a dispatch in flight, never swept.
    assert GitGrant.sweep(config.grant_dir) == []

    Process.exit(pid, :kill)
    # The launcher's watchdog sees the Port's pipe close and ends the session, itself included.
    :ok = wait_until(fn -> not os_pid_alive?(launcher) end, 15_000)

    assert GitGrant.sweep(config.grant_dir) == [grant]
    refute File.exists?(grant)
  end

  # A Session started directly, as `Run` starts one for an implement run: on a branch of its own,
  # so it arms the grant.
  defp start_session!(root, session_id \\ Session.uuid4()) do
    config = config!(root)
    {:ok, story} = Story.from_map(story_map(), config)
    run_dir = Path.join(root, "direct-run")
    File.mkdir_p!(run_dir)
    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), Session.uuid4())

    {:ok, pid} =
      GenServer.start(Session,
        config: config,
        story: story,
        worktree: Path.join(root, "repo"),
        run_dir: run_dir,
        trace: trace,
        parent: nil,
        waiter: self(),
        session_id: session_id,
        own_worktree: true
      )

    %{pid: pid, config: config, grant: GitGrant.path(config, session_id)}
  end

  # Traces `pid`'s calls to `mfas` and its sends, to this process. Trace messages from one traced
  # process reach the tracer in the order its events happened, which is what makes an ORDER
  # assertion deterministic rather than a race against that process's next few microseconds.
  defp trace_session(pid, mfas) do
    for mfa <- mfas, do: :erlang.trace_pattern(mfa, true, [:global])
    on_exit(fn -> for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global]) end)
    :erlang.trace(pid, true, [:call, :send])
  end

  # Once `pid` is gone: every event traced from it, in order, mapped by `tag` (nil drops one).
  defp traced_events(pid, tag) do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    collect_traced(pid, tag, [])
  end

  defp collect_traced(pid, tag, acc) do
    receive do
      {:trace, ^pid, _, _} = event -> collect_traced(pid, tag, [tag.(event) | acc])
      {:trace, ^pid, _, _, _} = event -> collect_traced(pid, tag, [tag.(event) | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.reject(&is_nil/1)
    end
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

  test "a later dispatch of the same story adopts the worktree the earlier run kept", %{
    root: root,
    state: state
  } do
    alias LoopctlRunner.{DispatchRun, Worktree}

    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "write_file"}])
    config = config!(root)
    story_id = LoopctlRunner.Session.uuid4()

    fields = %{
      repo: "fixture",
      repo_path: Path.join(root, "repo"),
      base: "master",
      branch: "loop/s1",
      wall_clock_s: 30,
      max_turns: 5
    }

    stories =
      for _ <- 1..2 do
        dispatch = %{
          "dispatch_id" => LoopctlRunner.Session.uuid4(),
          "story_id" => story_id,
          "repo" => "mkreyman/fixture"
        }

        {:ok, story} =
          DispatchRun.story(dispatch, fields, %{"id" => story_id, "title" => "t"}, config)

        story
      end

    [first, second] = stories
    assert first.id == second.id
    assert first.id == "story-" <> story_id

    assert Worktree.path_for(first.repo_path, first.id) ==
             Worktree.path_for(second.repo_path, second.id)

    try do
      earlier = Run.execute(config, first)
      assert {:kept, _} = earlier.teardown.worktree

      later = Run.execute(config, second)
      assert later.status == "succeeded"

      assert [%{"data" => %{"reused" => true}}] =
               Enum.filter(events!(later), &(&1["type"] == "worktree.created"))
    after
      restore.()
    end
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
    :ok = WorktreeLock.acquire(config.runs_dir, worktree, "holder", owner!())

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

  test "while a run holds its worktree, the lock names the run's UUID", %{
    root: root,
    state: state
  } do
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_AGENTS", "busy"}])
    config = config!(root)
    {:ok, story} = Story.from_map(story_map(%{"wall_clock_s" => 4}), config)
    worktree = Path.join([root, "repo", ".claude/worktrees/loop-s1"])
    task = Task.async(fn -> Run.execute(config, story) end)

    try do
      :ok =
        wait_until(fn -> WorktreeLock.live_holder(config.runs_dir, worktree) != nil end, 10_000)

      holder = WorktreeLock.live_holder(config.runs_dir, worktree)
      result = Task.await(task, 30_000)
      assert holder == result.run_id
    after
      restore.()
    end
  end

  test "a run that ends by exit still reports :finished, exactly once", %{
    root: root,
    state: state
  } do
    restore = fake_env!(state, [{"FAKE_CLAUDE_MODE", "stream"}])
    config = config!(root)
    {:ok, story} = Story.from_map(story_map(), config)
    test = self()

    on_stage = fn
      {:worktree, _} -> exit(:boom)
      event -> send(test, {:stage, event})
    end

    try do
      assert catch_exit(Run.execute(config, story, on_stage: on_stage)) == :boom
    after
      restore.()
    end

    assert_received {:stage, {:finished, %{status: "crashed", error: "exit: " <> _}}}
    refute_received {:stage, {:finished, _}}
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
    assert :ok = WorktreeLock.acquire(config.runs_dir, worktree, "next", owner!())
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

  test "a session that escalates and keeps working is stopped, and the run ends escalated", %{
    root: root,
    state: state
  } do
    result =
      run!(
        root,
        state,
        [{"FAKE_CLAUDE_MODE", "escalate_and_continue"}, {"FAKE_AGENTS", "busy"}],
        %{
          "wall_clock_s" => 30
        }
      )

    assert result.status == "escalated"
    assert result.session.duration_ms < 15_000

    events = events!(result)

    # Literal: nothing in the heredoc was expanded, and UTF-8 survived.
    assert [
             %{
               "data" => %{
                 "reason" =>
                   "Should the billing total include voided visits? It changes $5 or $10 per `visit` — a business call."
               }
             }
           ] = Enum.filter(events, &(&1["type"] == "session.escalation_requested"))

    assert "session.escalated" in types(events)
  end

  test "the escalation script cuts long UTF-8 reasons at characters, keeping valid JSON", %{
    root: root
  } do
    run_dir = Path.join(root, "esc-run")
    File.mkdir_p!(run_dir)
    reason = String.duplicate("a", 3999) <> "—tail"

    {_, 0} =
      System.cmd("/bin/sh", ["-c", ~s|printf '%s' "$REASON" \| "$SCRIPT"|],
        env: [
          {"LOOP_RUN_DIR", run_dir},
          {"LOOP_SESSION_ID", "s"},
          {"REASON", reason},
          {"SCRIPT", LoopctlRunner.Session.escalate_script()}
        ],
        stderr_to_stdout: true
      )

    line = run_dir |> Path.join("escalations.ndjson") |> File.read!() |> String.trim()
    assert {:ok, %{"reason" => recorded}} = JSON.decode(line)
    assert String.length(recorded) == 4000
    assert String.ends_with?(recorded, "—")
  end

  test "a session that escalates and exits 0 still ends escalated, not succeeded", %{
    root: root,
    state: state
  } do
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "escalate_and_exit"}])

    assert result.status == "escalated"
    assert result.session.exit_status == 0

    assert [%{"data" => %{"reason" => "The story contradicts an existing KB decision."}}] =
             Enum.filter(events!(result), &(&1["type"] == "session.escalation_requested"))

    assert {:ok, [line]} =
             result.run_dir
             |> Path.join("escalations.ndjson")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> then(&{:ok, &1})

    assert {:ok, %{"session_id" => sid}} = JSON.decode(line)
    assert sid == result.session.session_id
  end

  test "a worktree failure is recorded and nothing is started", %{root: root, state: state} do
    # An earlier story's branch with a commit of its own: refused, never adopted or retired.
    repo = Path.join(root, "repo")
    earlier = git!(repo, ["commit-tree", "master^{tree}", "-p", "master", "-m", "earlier story"])
    git!(repo, ["branch", "loop/s1", earlier])
    result = run!(root, state, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert result.status == "failed"
    assert result.error =~ "already exists without a worktree"
    refute File.exists?(Path.join(state, "session_id"))
    assert "worktree.failed" in types(events!(result))
  end
end
