defmodule LoopctlRunner.TriageRunTest do
  # Mutates PATH and FAKE_* in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{TriageRun, TriageVerdict, Worktree, WorktreeLock}
  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  # A REALISTIC escalate verdict: it carries a sentence in `escalation_reasons` as well as the
  # missing information, which is what the prompt requires of one and what `bare_escalation?/1`
  # looks for. Without it every run in this file logs that its escalation gave a person no words.
  @verdict %{
    "outcome" => "escalate",
    "confidence" => "high",
    "missing_information" => ["what?"],
    "escalation_reasons" => ["the form and the invoice disagree on which date is billed"]
  }

  @triage %{
    "record_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
    "issue_number" => 846,
    "html_url" => nil,
    "truncated" => false,
    "untrusted" => "<<<UNTRUSTED reported_issue n0nce>>>\n| it crashes\n<<<END n0nce>>>"
  }

  setup do
    root = tmp_dir!("triage-run")
    git_repo!(Path.join(root, "repo"))
    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    {:ok, root: root, state: state, config: config!(root)}
  end

  defp execute(ctx, fake_vars, opts \\ []) do
    config = Keyword.get(opts, :config, ctx.config)
    restore = fake_env!(ctx.state, fake_vars)

    try do
      TriageRun.execute(config, Keyword.get(opts, :triage, @triage), "mkreyman/fixture", opts)
    after
      restore.()
    end
  end

  test "a session that states a verdict produces it, validated", ctx do
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    assert {:verdict, verdict} = result.outcome
    assert verdict["outcome"] == "escalate"
    assert File.read!(TriageVerdict.file(result.run_dir)) == Jason.encode!(@verdict)
    assert {:ok, %{"status" => "verdict", "kind" => "triage"}} = RunStateRead.read(result.run_dir)
  end

  test "a triage whose claim ended before its session starts none", ctx do
    binding = %{"dispatch_id" => LoopctlRunner.Session.uuid4(), "claim_epoch" => 3}

    :ok =
      LoopctlRunner.ClaimEnded.record(
        ctx.config.runs_dir,
        binding["dispatch_id"],
        3,
        "trace",
        "x"
      )

    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], binding: binding)

    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    assert detail =~ "ended the claim"
    assert result.session == nil
    refute File.exists?(Path.join(ctx.state, "argv"))
  end

  test "an escalate carrying only bare codes is SENT, and said about", ctx do
    # The one moment the runner holds such a verdict and knows it is about to go. It is not
    # refused: `TriageVerdict.bare_escalation?/1` carries the argument, and the short of it is that
    # `verdict_invalid` would report that this run produced nothing, while loopctl accepts this and
    # routes a human to it. So the outcome must still be the verdict, and the line must still be
    # there — a check nobody logs is a check that changes nothing.
    thin =
      Map.put(@verdict, "escalation_reasons", [
        hd(LoopctlRunner.TriagePrompt.reason_codes().gating)
      ])

    log =
      capture_log(fn ->
        result =
          execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(thin)}])

        assert {:verdict, ^thin} = result.outcome
      end)

    assert log =~ "carries no words a person can act on"
  end

  test "the session is launched with the TRIAGE containment, not the implement one", ctx do
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    argv = File.read!(Path.join(ctx.state, "argv"))

    # A triage session's containment is now its LENSES, not its own flags: it runs the same
    # posture an implement session does, and what is shipped that an implement launch does not
    # ship is the lens definitions, each declaring a read-only tool set of its own.
    refute argv =~ "--tools"
    refute argv =~ "--allowedTools"
    assert argv =~ "--permission-mode\nbypassPermissions\n"
    refute argv =~ "--disallowedTools"
    # A dispatched session keeps the operator's MCP set: only an eval overrides it (US-48.10).
    refute argv =~ "--strict-mcp-config"
    refute argv =~ "--mcp-config"
    # No LOOP_BRANCH: it served only loop-push, retired with thread mode (contract 1.23.0).
    refute File.read!(Path.join(ctx.state, "env")) =~ ~r/^LOOP_BRANCH=/m
    assert argv =~ "--agents\n"
    assert result.session.exit_status == 0
  end

  test "a triage session gets NO subagent git grant: it has no branch of its own", ctx do
    # The grant exists so an engineer agent can commit to the branch the runner cut for a story.
    # A triage run has no branch of its own to commit to. The RUNNER's environment carries a
    # LOOP_GIT_GRANT naming a file that exists — a daemon started from inside a loop session
    # would — and the session must still see none: inherited, it would read as this session's.
    decoy = Path.join(ctx.root, "inherited-grant")
    File.write!(decoy, "not this session's\n")

    result =
      execute(ctx, [
        {"FAKE_CLAUDE_MODE", "stream"},
        {"FAKE_VERDICT", Jason.encode!(@verdict)},
        {"LOOP_GIT_GRANT", decoy}
      ])

    assert File.read!(Path.join(ctx.state, "git_grant")) == "GIT_GRANT ABSENT\n"
    assert File.read!(Path.join(ctx.state, "git_grant_env")) == "LOOP_GIT_GRANT UNSET\n"

    refute File.exists?(LoopctlRunner.GitGrant.path(config!(ctx.root), result.session.session_id))
  end

  # Compared resolved: on macOS the temp dir lives under /var, a symlink to /private/var, and the
  # fake records the cwd it resolved.
  defp real_checkout(ctx), do: real(Path.join(ctx.root, "repo"))

  defp real(path) do
    {real_parent, 0} = System.cmd("realpath", [Path.dirname(path)])
    Path.join(String.trim(real_parent), Path.basename(path))
  end

  # Keyed, as the run keys them, by the checkout path the CONFIG names.
  defp shared_tree(ctx),
    do: Worktree.triage_tree_path(ctx.config.runs_dir, Path.join(ctx.root, "repo"))

  defp own_tree(ctx, run_id),
    do: Worktree.triage_tree_path(ctx.config.runs_dir, Path.join(ctx.root, "repo"), run_id)

  test "a triage run works in the repo's REUSED detached tree, released for the next run", ctx do
    # Not in the operator's live checkout: the session gets the repo's one triage tree, at the
    # commit the checkout has out, on no branch — and it stays, so the next run refreshes it rather
    # than paying for a checkout, and the session's cwd (and so its project directory) is stable.
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    checkout = real_checkout(ctx)
    tree = shared_tree(ctx)

    assert File.read!(Path.join(ctx.state, "cwd")) |> String.trim() == real(tree)
    assert File.dir?(tree)
    assert git!(tree, ["rev-parse", "HEAD"]) == git!(checkout, ["rev-parse", "HEAD"])
    assert git!(tree, ["rev-parse", "--abbrev-ref", "HEAD"]) == "HEAD"
    # The checkout itself is untouched: still on its own branch, and gaining no tree directory —
    # the tree is the runner's, under its runs_dir.
    assert git!(checkout, ["rev-parse", "--abbrev-ref", "HEAD"]) == "master"
    refute File.exists?(Path.join(checkout, ".claude"))
    assert String.starts_with?(tree, Path.join(ctx.config.runs_dir, ".triage-trees"))

    # Recorded where the reaper looks, as scratch, and RELEASED: no longer this run's.
    recorded = tree

    assert {:ok,
            %{
              "worktree" => %{"status" => "released", "path" => ^recorded, "scratch" => true}
            }} = RunStateRead.read(result.run_dir)

    assert WorktreeLock.live_holder(ctx.config.runs_dir, recorded) == nil
  end

  test "the reused tree is brought to the checkout's commit, and cleaned, for every run", ctx do
    # What an earlier session left there — untracked, and ignored — is gone before the next one
    # starts, and a checkout that moved on is judged at its new commit.
    execute(ctx, [{"FAKE_CLAUDE_MODE", "write_file"}])
    checkout = real_checkout(ctx)
    tree = shared_tree(ctx)
    assert File.exists?(Path.join(tree, "wip.txt"))

    File.write!(Path.join(checkout, ".gitignore"), "*.log\n")
    git!(checkout, ["add", ".gitignore"])
    git!(checkout, ["commit", "-q", "-m", "ignore logs"])
    File.write!(Path.join(tree, "build.log"), "left by a session")

    execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert git!(tree, ["rev-parse", "HEAD"]) == git!(checkout, ["rev-parse", "HEAD"])
    refute File.exists?(Path.join(tree, "wip.txt"))
    refute File.exists?(Path.join(tree, "build.log"))
  end

  test "a run that finds the reused tree held cuts its OWN, removed with what it wrote", ctx do
    # Two triage runs on one repo never share a tree. The second gets one of its own, and its
    # teardown removes it whatever the session left in it — an untracked file here — and the
    # Claude project directory its one-off cwd made. Only that one: the reused tree's cwd is the
    # same for every run on this repo, so its project directory is one, and stays.
    execute(ctx, [
      {"FAKE_CLAUDE_MODE", "stream"},
      {"FAKE_PROJECTS_DIR", ctx.config.claude_projects_dir}
    ])

    shared_project = File.read!(Path.join(ctx.state, "project_dir")) |> String.trim()
    shared = shared_tree(ctx)
    :ok = WorktreeLock.acquire(ctx.config.runs_dir, shared, "another-live-run", owner!())

    result =
      execute(ctx, [
        {"FAKE_CLAUDE_MODE", "write_file"},
        {"FAKE_PROJECTS_DIR", ctx.config.claude_projects_dir}
      ])

    own = own_tree(ctx, result.run_id)
    assert File.read!(Path.join(ctx.state, "cwd")) |> String.trim() == real(own)
    refute File.dir?(own)
    refute git!(real_checkout(ctx), ["worktree", "list", "--porcelain"]) =~ result.run_id
    # The other run's lock is not this run's to release.
    assert WorktreeLock.live_holder(ctx.config.runs_dir, shared) == "another-live-run"

    project = File.read!(Path.join(ctx.state, "project_dir")) |> String.trim()
    assert project =~ result.run_id
    refute File.exists?(project)
    assert File.dir?(shared_project)

    recorded = own

    assert {:ok,
            %{"worktree" => %{"status" => "removed", "path" => ^recorded, "scratch" => true}}} =
             RunStateRead.read(result.run_dir)
  end

  test "a raise after the tree is cut still removes it, and is reported with a wire form", ctx do
    # Between the cut and the session sit a state write and the prompt. A raise there used to leave
    # the tree on disk and the run with an {:error, _}, which has no wire form. A lens list that is
    # not a list is what makes the prompt raise here.
    shared = shared_tree(ctx)
    :ok = WorktreeLock.acquire(ctx.config.runs_dir, shared, "another-live-run", owner!())

    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], lenses: :not_a_list)

    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    assert detail =~ "could not be prepared"
    refute File.exists?(Path.join(ctx.state, "argv"))
    refute File.dir?(own_tree(ctx, result.run_id))
  end

  test "the prompt carries this run's token, and the token file is not the prompt's neighbour",
       ctx do
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    argv = File.read!(Path.join(ctx.state, "argv"))
    token = File.read!(Path.join(result.run_dir, "verdict.token"))

    assert argv =~ token
    assert File.exists?(Path.join(result.run_dir, "escalate.token"))
    # The verdict was recorded BY the token, so the fake could only have got it from the prompt.
    assert {:verdict, _} = result.outcome
  end

  test "a session that writes nothing is incomplete, and says which way", ctx do
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
    assert {:incomplete, "no_verdict_written", _} = result.outcome

    assert {:ok, %{"status" => "incomplete:no_verdict_written"}} =
             RunStateRead.read(result.run_dir)
  end

  test "a session that exits non-zero is incomplete as crashed", ctx do
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_EXIT", "9"}])
    assert {:incomplete, "session_crashed", detail} = result.outcome
    assert detail =~ "exited 9"
  end

  test "a session out of turns wrote no verdict; it did not crash, though it exits 1", ctx do
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "max_turns"}])
    assert {:incomplete, "no_verdict_written", "the session ran out of turns"} = result.outcome
  end

  test "bytes that are not a verdict are incomplete as invalid, never sent", ctx do
    # A JSON object the script records, and two ways for it not to be a verdict: one the schema
    # refuses, one only the conditional rule catches.
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", ~s({"outcome":"story"})}])

    assert {:incomplete, "verdict_invalid", detail} = result.outcome
    assert detail =~ "missing confidence"

    result =
      execute(ctx, [
        {"FAKE_CLAUDE_MODE", "stream"},
        {"FAKE_VERDICT", ~s({"outcome":"story","confidence":"high"})}
      ])

    assert {:incomplete, "verdict_invalid", detail} = result.outcome
    assert detail =~ "carries no draft story"
  end

  test "the run records its owner, so the reaper does not kill a live triage session", ctx do
    # Reaper.orphan? calls any running state without an owner an orphan, and Run.execute reaps
    # before every implement dispatch — so without this the next story on the same machine would
    # terminate a healthy triage session and the verdict would never be stated.
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    {:ok, state} = LoopctlRunner.RunState.read(result.run_dir)

    assert LoopctlRunner.Owner.alive?(state)
    assert state["beam_os_pid"] == System.pid() |> String.to_integer()
  end

  test "the run announces its directory before it writes any state, and before the session runs",
       ctx do
    # A task killed from outside never reaches the end of the run, and what it leaves behind is a
    # state at `running` with a live owner, which `Runs.in_flight/2` counts for the life of the
    # BEAM. Whoever supervises the run can only close that by knowing the directory WHILE the run
    # is still going, so the announcement is the fix, and being early is the whole of it.
    test = self()

    result =
      execute(
        ctx,
        [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
        on_start: fn run ->
          send(
            test,
            {:announced, run, LoopctlRunner.RunState.read(run.run_dir),
             File.exists?(Path.join(ctx.state, "argv"))}
          )
        end
      )

    assert_received {:announced, run, state, session_launched?}
    assert run.run_dir == result.run_dir
    assert run.run_id == result.run_id
    assert File.dir?(run.run_dir)

    # No state yet, and that ordering is the point: a state at `running` naming a live owner that
    # nobody knows the directory of is a run nothing can close and nothing will reap. Announced
    # first, the worst a kill in this window leaves is an empty directory.
    assert state == {:error, :enoent}

    # Before the session: the fake CLI had not been launched when the announcement was made.
    refute session_launched?
    assert File.exists?(Path.join(ctx.state, "argv"))
    assert {:ok, %{"kind" => "triage", "status" => "verdict"}} = RunStateRead.read(result.run_dir)
  end

  test "the run records its outcome as the message that states it, beside the verdict", ctx do
    # What a run that outlives every Control leaves behind: its outcome reaches Control as a
    # message, and a message reaches nobody when none is registered to take it.
    binding = %{
      "dispatch_id" => "1f0b6b8e-2c3d-4e5f-8a9b-0c1d2e3f4a5b",
      "claim_epoch" => 3,
      "story_id" => "9fdefcf9-b7a4-4062-86f1-011d691db036"
    }

    result =
      execute(
        ctx,
        [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
        binding: binding
      )

    assert [{run_dir, recorded}] = LoopctlRunner.PendingVerdicts.all(ctx.config.runs_dir)
    assert run_dir == result.run_dir

    assert recorded == %{
             "dispatch_id" => binding["dispatch_id"],
             "claim_epoch" => 3,
             "verdict" => @verdict
           }

    # Checkable by exactly what checks a message kept for a restart, because it is one.
    assert {:ok, ^recorded} = LoopctlRunner.TriageDispatch.sendable(recorded)
  end

  test "a run with no dispatch to answer records no message, and complains about none", ctx do
    log =
      capture_log(fn ->
        result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
        refute File.exists?(LoopctlRunner.PendingVerdicts.file(result.run_dir))
      end)

    # Not an error either: a run nobody dispatched has nobody to report to, which is the whole
    # difference between no message and a message that cannot be sent.
    refute log =~ "not a message anything can send"
    assert LoopctlRunner.PendingVerdicts.all(ctx.config.runs_dir) == []
  end

  test "an announcement that raises does not take the run down with it", ctx do
    result =
      execute(
        ctx,
        [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
        on_start: fn _run -> raise "the listener is gone" end
      )

    assert {:verdict, _} = result.outcome
  end

  test "the session is given the ESCALATE token, not the verdict one", ctx do
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
    argv = File.read!(Path.join(ctx.state, "argv"))
    verdict_token = File.read!(Path.join(result.run_dir, "verdict.token"))
    escalate_token = File.read!(Path.join(result.run_dir, "escalate.token"))

    assert verdict_token != escalate_token
    # Minting the escalate token ARMS the check in loop-escalate: a prompt carrying the verdict's
    # would have every escalation refused, so a session that cannot work at all could say nothing.
    assert argv =~ "#{LoopctlRunner.Session.escalate_script()} #{escalate_token}"
    assert argv =~ "loop-verdict #{verdict_token}"
  end

  test "a session that escalates is incomplete with its own words, not a cause the runner guessed",
       ctx do
    result =
      execute(ctx, [
        {"FAKE_CLAUDE_MODE", "stream"},
        {"FAKE_ESCALATE", "the checkout will not read"}
      ])

    assert {:incomplete, reason, detail} = result.outcome
    # Never checkout_unreadable: the runner did not check the checkout, the session said so.
    assert reason == "no_verdict_written"
    assert detail =~ "the session escalated: the checkout will not read"
    refute detail =~ "{"
  end

  test "a record_id that is not a uuid fails before a run directory exists", ctx do
    for bad <- ["../escape", "not-a-uuid", nil] do
      triage = Map.put(@triage, "record_id", bad)
      result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage: triage)

      assert {:error, reason} = result.outcome
      assert reason =~ "record_id" or reason =~ "names no record_id"
      assert result.run_dir == nil
    end

    refute ctx.config.runs_dir |> Path.join("..") |> Path.join("escape") |> File.exists?()
  end

  test "the repo's session_env reaches a triage session, keyed as repos is", ctx do
    # Keyed by the name `repos` uses, never the checkout directory's: with repos
    # {"fixture" => ".../repo"} the basename is "repo", and a lookup by it finds nothing — the
    # session then starts with none of the operator's knobs and nothing says so.
    config =
      config!(ctx.root, %{"session_env" => %{"fixture" => %{"RUNNER_ENV_PROBE" => "t_{run}"}}})

    restore = fake_env!(ctx.state, [{"FAKE_CLAUDE_MODE", "stream"}])

    result =
      try do
        TriageRun.execute(config, @triage, "mkreyman/fixture")
      after
        restore.()
      end

    assert File.read!(Path.join(ctx.state, "env")) =~
             ~r/^RUNNER_ENV_PROBE=t_#{binary_part(result.run_id, 0, 8)}$/m
  end

  test "deadline_at stops the session in time, and the detail names the deadline", ctx do
    room = ctx.config.kill_grace_s + LoopctlRunner.Story.deadline_margin_s() + 2
    deadline = DateTime.utc_now() |> DateTime.add(room, :second)
    started = System.monotonic_time(:millisecond)

    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "hang"}], wall_clock_s: 30, deadline_at: deadline)

    assert DateTime.compare(DateTime.utc_now(), deadline) == :lt
    assert {:incomplete, "wall_clock_exceeded", detail} = result.outcome
    # Which bound it was: loopctl's placement, not this runner's wall clock budget.
    assert detail =~ "deadline_at"
    assert result.session.reason == :wall_clock_exceeded
    assert System.monotonic_time(:millisecond) - started < 15_000
  end

  test "a wall clock stop says so, and not the deadline", ctx do
    deadline = DateTime.utc_now() |> DateTime.add(3600, :second)
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "hang"}], wall_clock_s: 1, deadline_at: deadline)

    assert {:incomplete, "wall_clock_exceeded", "the session ran out of wall clock"} =
             result.outcome
  end

  test "one past its deadline_at when it begins does nothing and owes nothing", ctx do
    # Past for the guard while still in the future: inside the kill grace and the margin.
    deadline = DateTime.utc_now() |> DateTime.add(ctx.config.kill_grace_s, :second)

    binding = %{
      "dispatch_id" => LoopctlRunner.Session.uuid4(),
      "claim_epoch" => 3,
      "story_id" => LoopctlRunner.Session.uuid4()
    }

    log =
      capture_log(fn ->
        send(
          self(),
          {:result,
           execute(
             ctx,
             [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
             deadline_at: deadline,
             binding: binding
           )}
        )
      end)

    assert_received {:result, result}
    # Nothing tried to turn "did not start" into a message and failed at it.
    refute log =~ "outcome"

    assert {:deadline_passed, detail} = result.outcome
    assert detail =~ ~r/^deadline_passed: /
    assert result.session == nil
    # No session, no tree, and no message recorded for a restart to send.
    refute File.exists?(Path.join(ctx.state, "argv"))
    assert LoopctlRunner.PendingVerdicts.all(ctx.config.runs_dir) == []

    assert {:ok, %{"status" => "deadline_passed", "terminal_reported" => "skipped"} = recorded} =
             RunStateRead.read(result.run_dir)

    refute Map.has_key?(recorded, "worktree")
  end

  test "one whose deadline passes before its session starts owes nothing either", ctx do
    config = ctx.config
    # Room for the run-start check with seconds to spare, then `on_start` — announced after that
    # check and before the session — waits the guard out: the check immediately before the session
    # is what refuses it.
    room =
      config.kill_grace_s + LoopctlRunner.Story.deadline_margin_s() + config.min_session_s + 3

    deadline = DateTime.utc_now() |> DateTime.add(room, :second)

    wait_out = fn _run ->
      :ok =
        wait_until(fn ->
          LoopctlRunner.Story.check_deadline(deadline, 1800, config, DateTime.utc_now()) != :ok
        end)
    end

    binding = %{
      "dispatch_id" => LoopctlRunner.Session.uuid4(),
      "claim_epoch" => 3,
      "story_id" => LoopctlRunner.Session.uuid4()
    }

    result =
      execute(
        ctx,
        [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
        deadline_at: deadline,
        binding: binding,
        on_start: wait_out
      )

    # The same outcome as a start check that found it passed: no message, nothing owed — never an
    # `incomplete` `wall_clock_exceeded` for a session that never ran.
    assert {:deadline_passed, detail} = result.outcome
    assert detail =~ ~r/^deadline_passed: /
    assert result.session == nil
    refute File.exists?(Path.join(ctx.state, "argv"))
    # Refused inside the tree's `try`: the tree it cut was released as after any session.
    {:ok, events} = LoopctlRunner.Trace.read(Path.join(result.run_dir, "trace.ndjson"))
    types = Enum.map(events, & &1["type"])
    assert "triage.deadline_passed" in types
    refute "session.started" in types
    assert Enum.any?(types, &(&1 in ["worktree.released", "worktree.removed"]))
    assert LoopctlRunner.PendingVerdicts.all(config.runs_dir) == []

    assert {:ok, %{"status" => "deadline_passed", "terminal_reported" => "skipped"}} =
             RunStateRead.read(result.run_dir)
  end

  test "a budget over this runner's ceiling is refused, not quietly granted", ctx do
    # Story.from_map enforces these for every implement run; a triage dispatch asking for more
    # could otherwise hold a session open past any ceiling the operator set.
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], wall_clock_s: 10_000)
    assert {:error, reason} = result.outcome
    assert reason =~ "wall clock"

    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], max_turns: 10_000)
    assert {:error, reason} = result.outcome
    assert reason =~ "turns"

    # And the defaults respect them rather than assuming 1800/60.
    assert {:verdict, _} =
             execute(ctx, [
               {"FAKE_CLAUDE_MODE", "stream"},
               {"FAKE_VERDICT", Jason.encode!(@verdict)}
             ]).outcome
  end

  test "a checkout the runner cannot read is a reportable incomplete, not a runner error", ctx do
    # checkout/2 LOOKED, so the cause is verified and the contract has a word for it. As
    # {:error, _} this had no wire form at all: the dispatch it answers would sit in flight for
    # ever, which is the failure the incomplete path exists to prevent. Both ways of failing —
    # no configured checkout, and a path that is not a directory — report the same reason with
    # their own detail.
    restore = fake_env!(ctx.state, [{"FAKE_CLAUDE_MODE", "stream"}])

    missing = Path.join(ctx.root, "not-a-repo")
    File.write!(missing, "")
    config = config!(ctx.root, %{"repos" => %{"fixture" => missing}})

    results =
      try do
        [
          TriageRun.execute(ctx.config, @triage, "someone/absent"),
          TriageRun.execute(config, @triage, "mkreyman/fixture")
        ]
      after
        restore.()
      end

    assert [absent, not_a_dir] = results
    assert {:incomplete, "checkout_unreadable", reason} = absent.outcome
    assert reason =~ "no local checkout"
    assert {:incomplete, "checkout_unreadable", reason} = not_a_dir.outcome
    assert reason =~ "is not a directory"

    for result <- results do
      assert result.session == nil

      assert {:ok, %{"status" => "incomplete:checkout_unreadable"}} =
               RunStateRead.read(result.run_dir)
    end

    refute File.exists?(Path.join(ctx.state, "argv"))
  end

  test "a detail longer than the contract allows is cut, never sent whole", ctx do
    # An escalating session's own words are admitted up to 4000 characters by Session, and the
    # contract caps detail at 300. Over it the WHOLE message is refused invalid_payload, which
    # permanent_errors makes permanent, so the least important field in the message would take
    # the verdict down with it.
    long = String.duplicate("x", 5_000)

    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_ESCALATE", long}])

    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    assert String.length(detail) == TriageRun.max_detail()
    assert TriageRun.max_detail() == 300

    # And the cut detail still validates as the message field it becomes.
    assert LoopctlRunner.Contract.validate_against(
             LoopctlRunner.Contract.schema_def("RunnerTriageVerdictMessage")
             |> get_in(["properties", "detail"]),
             detail,
             "detail"
           ) == :ok
  end

  test "a verdict path that will not read is reported by WHAT IS THERE, not by assumption", ctx do
    # loopctl asked for an IO failure to reach it as an incomplete rather than a runner error, on
    # the checkout_unreadable argument: an error has no wire form and strands the dispatch. Which
    # incomplete is a different question, and the contract answers it — verdict_invalid means the
    # session DID write one. A DIRECTORY at the verdict path is not something loop-verdict can
    # create, so nothing was written and saying otherwise asserts a cause nobody checked.
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT_UNREADABLE", "dir"}])

    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    assert detail =~ "could not be read"

    assert {:ok, %{"status" => "incomplete:no_verdict_written"}} =
             RunStateRead.read(result.run_dir)

    # A regular file that will not read IS the session's, because only loop-verdict links one in.
    unreadable =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT_UNREADABLE", "chmod"}])

    assert {:incomplete, "verdict_invalid", detail} = unreadable.outcome
    assert detail =~ "could not be read"
  end

  test "a tree the runner cannot cut is its own failure; a checkout git cannot judge is unreadable",
       ctx do
    # The ways cutting the detached worktree fails are different parties' failures. A runs_dir
    # where no tree can be cut — a FILE where the trees' directory goes — is local to this runner
    # and says nothing about the checkout, so it is the contract's runner-side report, not
    # checkout_unreadable. (Something in the way AT the tree's path is not a failure at all: it is
    # moved aside and the tree cut, `Worktree.refresh_detached/2`.) A checkout with no commit to
    # judge, or one git will not read as a repository at all, is exactly checkout_unreadable — and
    # the two say which, in git's own words.
    restore = fake_env!(ctx.state, [{"FAKE_CLAUDE_MODE", "stream"}])
    blocked = Path.join(ctx.config.runs_dir, ".triage-trees")
    File.mkdir_p!(ctx.config.runs_dir)
    File.write!(blocked, "in the way")

    empty = Path.join(ctx.root, "empty")
    File.mkdir_p!(empty)
    git!(empty, ["init", "-q", "-b", "master"])
    no_commit = config!(ctx.root, %{"repos" => %{"fixture" => empty}})

    plain = Path.join(ctx.root, "plain")
    File.mkdir_p!(plain)
    not_a_repo = config!(ctx.root, %{"repos" => %{"fixture" => plain}})

    [cut, unreadable, not_git] =
      try do
        [
          TriageRun.execute(ctx.config, @triage, "mkreyman/fixture"),
          TriageRun.execute(no_commit, @triage, "mkreyman/fixture"),
          TriageRun.execute(not_a_repo, @triage, "mkreyman/fixture")
        ]
      after
        restore.()
      end

    assert {:incomplete, "no_verdict_written", detail} = cut.outcome
    assert detail =~ "could not be prepared"
    assert {:incomplete, "checkout_unreadable", reason} = unreadable.outcome
    assert reason =~ "no commit checked out"
    assert reason =~ "fatal:"
    assert {:incomplete, "checkout_unreadable", reason} = not_git.outcome
    assert reason =~ "will not read"
    assert reason =~ "not a git repository"
    refute File.exists?(Path.join(ctx.state, "argv"))

    # Nothing of the run's is at that path, so the entry is terminal and the reaper leaves what is
    # there alone; and the reused tree's lock is not left held by a run that has ended.
    assert File.read!(blocked) == "in the way"

    assert {:ok, %{"worktree" => %{"status" => "not_prepared"}}} =
             RunStateRead.read(cut.run_dir)

    assert WorktreeLock.live_holder(ctx.config.runs_dir, shared_tree(ctx)) == nil
  end

  test "a tree's submodules are initialised in it", ctx do
    # A checkout with a submodule: judged without it, a session reads an empty directory where
    # code is. File transport is refused for submodules by default, so the test allows it for the
    # runner's git through the environment every git it starts inherits.
    sub = git_repo!(Path.join(ctx.root, "sub"))
    checkout = Path.join(ctx.root, "repo")

    git!(checkout, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendored"])

    git!(checkout, ["commit", "-q", "-m", "vendor"])
    System.put_env("GIT_CONFIG_PARAMETERS", "'protocol.file.allow'='always'")

    try do
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
    after
      System.delete_env("GIT_CONFIG_PARAMETERS")
    end

    readme = Path.join([shared_tree(ctx), "vendored", "README.md"])
    assert File.read!(readme) == "fixture\n"

    # And in the REUSED tree on the next run, which refreshes rather than cuts: emptied here, it is
    # initialised again.
    git!(shared_tree(ctx), ["submodule", "deinit", "-q", "-f", "vendored"])
    refute File.exists?(readme)
    System.put_env("GIT_CONFIG_PARAMETERS", "'protocol.file.allow'='always'")

    try do
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
    after
      System.delete_env("GIT_CONFIG_PARAMETERS")
    end

    assert File.read!(readme) == "fixture\n"
  end

  test "a submodule whose remote the runner cannot reach comes from the checkout's own clone",
       ctx do
    # The runner's git runs with the operator's credentials scrubbed, so a PRIVATE submodule's
    # remote is out of its reach — as this deleted one is. The clone his checkout already has is
    # not. No GIT_CONFIG_PARAMETERS: allowing the local transport is the runner's own doing.
    sub = git_repo!(Path.join(ctx.root, "sub"))
    checkout = Path.join(ctx.root, "repo")

    git!(checkout, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "vendored"])

    git!(checkout, ["commit", "-q", "-m", "vendor"])
    File.rm_rf!(sub)

    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert File.read!(Path.join([shared_tree(ctx), "vendored", "README.md"])) == "fixture\n"
    refute Map.has_key?(elem(RunStateRead.read(result.run_dir), 1), "submodules_missing")
  end

  test "an unreadable lock on the reused tree is stale, never a tree lost for good", ctx do
    # A corrupt lock file names no live run, so nothing it could protect is running. Read as held,
    # every later run on this repo would cut a tree of its own for ever.
    shared = shared_tree(ctx)

    :ok =
      WorktreeLock.acquire(
        ctx.config.runs_dir,
        shared,
        "a-run-whose-lock-was-truncated",
        owner!()
      )

    [lock] = Path.wildcard(Path.join([ctx.config.runs_dir, "locks", "*.lock"]))
    File.write!(lock, "")

    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])

    assert File.read!(Path.join(ctx.state, "cwd")) |> String.trim() == real(shared)

    assert {:ok, %{"worktree" => %{"status" => "released", "path" => ^shared}}} =
             RunStateRead.read(result.run_dir)

    assert WorktreeLock.live_holder(ctx.config.runs_dir, shared) == nil
  end

  test "an exit while the tree is given back never replaces the verdict the run has", ctx do
    # `Trace.emit/4` is a GenServer call, and the release runs in the `after` that follows the
    # judgement. The trace dies exactly as the release reaches it — an exit, not a raise — and the
    # verdict must still be the outcome, not an {:error, _} with no wire form.
    Process.flag(:trap_exit, true)
    test = self()

    killer =
      spawn_link(fn ->
        trace = find_trace(test)

        :sys.install(trace, {
          fn state, event, _name ->
            # A signal, not `exit/1`: `sys` catches what a debug function raises or exits with.
            if inspect(event) =~ "worktree.released",
              do: Process.exit(self(), :kill),
              else: state
          end,
          nil
        })

        send(test, :installed)
      end)

    log =
      capture_log(fn ->
        result =
          execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

        send(test, {:result, result})
      end)

    Process.flag(:trap_exit, false)
    assert_received :installed
    assert_received {:result, result}
    assert {:verdict, %{"outcome" => "escalate"}} = result.outcome
    assert log =~ "worktree release could not be recorded"
    # The lock is still given back.
    assert WorktreeLock.live_holder(ctx.config.runs_dir, shared_tree(ctx)) == nil
    Process.exit(killer, :kill)
  end

  # The trace this test's own run started: linked to, so an ancestor of, the test process.
  defp find_trace(test) do
    Enum.find(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          match?({LoopctlRunner.Trace, :init, 1}, dict[:"$initial_call"]) and
            test in Keyword.get(dict, :"$ancestors", [])

        _ ->
          false
      end
    end) || (Process.sleep(5) && find_trace(test))
  end

  test "a tree that could not be marked nor removed is recorded as existing, for the reaper",
       ctx do
    # A git that will not read the new tree's private directory (so the marker cannot be written)
    # and will not remove it either. The tree is left, so the entry must say a tree exists —
    # `not_prepared` is what the reaper skips, and the tree would stay for ever.
    real_git = System.find_executable("git")
    bin = Path.join(ctx.root, "git-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    case "$*" in
      *.triage-trees*--absolute-git-dir*|*"worktree remove"*.triage-trees*) exit 1 ;;
    esac
    exec #{real_git} "$@"
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)

    :ok =
      WorktreeLock.acquire(ctx.config.runs_dir, shared_tree(ctx), "another-live-run", owner!())

    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)

    result =
      try do
        execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
      after
        System.put_env("PATH", previous)
      end

    own = own_tree(ctx, result.run_id)
    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    # The detail is fit to the contract's length and starts with the tree's path, so how much
    # of the tail survives depends on TMPDIR (a CI slot's is long enough to cut "removed").
    # That the removal failed is asserted on the run state below, which no path shortens.
    assert detail =~ "cannot mark #{own}"
    assert String.length(detail) <= LoopctlRunner.TriageRun.max_detail()
    refute File.exists?(Path.join(ctx.state, "argv"))
    assert File.dir?(own)

    assert {:ok,
            %{"worktree" => %{"status" => "remove_failed", "path" => ^own, "scratch" => true}}} =
             RunStateRead.read(result.run_dir)
  end

  test "a triage run reaps an orphaned triage tree, and its project directory, before it starts",
       ctx do
    # Not only an implement run: a runner sent nothing but triage would otherwise keep a dead run's
    # tree, and the Claude project directory its one-off cwd made, until an implement dispatch.
    orphan_id = LoopctlRunner.Session.uuid4()
    tree = own_tree(ctx, orphan_id)
    {:ok, sha} = Worktree.create_detached(Path.join(ctx.root, "repo"), tree)
    project = Path.join(ctx.config.claude_projects_dir, "-private-" <> orphan_id)
    File.mkdir_p!(project)
    orphan = Path.join(ctx.config.runs_dir, "triage-orphan")
    File.mkdir_p!(orphan)
    {dead, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])

    LoopctlRunner.RunState.update(orphan, %{
      "run_id" => orphan_id,
      "kind" => "triage",
      "status" => "running",
      "beam_os_pid" => String.to_integer(String.trim(dead)),
      "repo_path" => Path.join(ctx.root, "repo"),
      "worktree" => %{
        "path" => tree,
        "branch" => "",
        "base" => sha,
        "status" => "created",
        "scratch" => true
      }
    })

    execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])

    refute File.dir?(tree)
    refute File.exists?(project)
    assert {:ok, %{"status" => "reaped"}} = RunStateRead.read(orphan)
  end

  test "the tree is recorded CREATED before its submodules, and a failed one is named to the session",
       ctx do
    # A submodule whose "remote" is a script: when git runs it, it copies the run's state.json
    # aside, which is what the state said at the moment the submodule step was under way — and then
    # fails, as an unreachable remote does. A raise in that step must find the tree recorded as
    # existing, so it goes through the release path and never reads as a tree never cut.
    checkout = Path.join(ctx.root, "repo")
    snapshot = Path.join(ctx.root, "state-during-submodules.json")
    remote = Path.join(ctx.root, "remote.sh")

    File.write!(remote, """
    #!/bin/sh
    cat #{ctx.config.runs_dir}/triage-*/state.json > #{snapshot}
    exit 1
    """)

    File.chmod!(remote, 0o755)

    File.write!(Path.join(checkout, ".gitmodules"), """
    [submodule "gone"]
    \tpath = gone
    \turl = ext::#{remote}
    """)

    sha = git!(checkout, ["rev-parse", "HEAD"])
    git!(checkout, ["update-index", "--add", "--cacheinfo", "160000,#{sha},gone"])
    git!(checkout, ["add", ".gitmodules"])
    git!(checkout, ["commit", "-q", "-m", "a submodule whose fetch records the state"])
    System.put_env("GIT_CONFIG_PARAMETERS", "'protocol.ext.allow'='always'")

    log =
      try do
        capture_log(fn ->
          send(self(), {:result, execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])})
        end)
      after
        System.delete_env("GIT_CONFIG_PARAMETERS")
      end

    assert_received {:result, result}
    shared = shared_tree(ctx)

    assert %{"worktree" => %{"status" => "created", "path" => ^shared}} =
             snapshot |> File.read!() |> Jason.decode!()

    # The session is told which paths may be empty, and why that is not the report's defect.
    argv = File.read!(Path.join(ctx.state, "argv"))
    assert argv =~ "could NOT initialise this checkout's submodules"
    assert argv =~ ~s|"gone"|

    # And the run says so where a reader of the run looks: its state and its trace.
    assert {:ok, %{"submodules_missing" => ["gone"]}} = RunStateRead.read(result.run_dir)
    {:ok, events} = LoopctlRunner.Trace.read(Path.join(result.run_dir, "trace.ndjson"))
    assert [missing] = Enum.filter(events, &(&1["type"] == "worktree.submodules_missing"))
    assert missing["data"]["paths"] == ["gone"]
    assert log =~ "submodules of"
  end

  test "a run the runner cannot prepare is reported, never left without a wire form", ctx do
    # The tokens are written AFTER the run directory and state.json exist, so the dispatch is
    # already this runner's by then. A read-only or full runs volume is the same operator failure
    # that makes a verdict file unreadable, one step earlier — and as {:error, _} it had no wire
    # form at all, so the dispatch it answers would sit in flight for ever.
    #
    # The failure is planted rather than simulated, and without a seam in the module: a DIRECTORY
    # where verdict.token goes, so File.touch refuses it. The run directory carries a timestamp to
    # the second, so both the current second's name and the next one are prepared and whichever
    # the run picks is the one it fails in.
    restore = fake_env!(ctx.state, [{"FAKE_CLAUDE_MODE", "stream"}])
    run_id = LoopctlRunner.Session.uuid4()

    for offset <- [0, 1] do
      stamp =
        DateTime.utc_now()
        |> DateTime.add(offset, :second)
        |> Calendar.strftime("%Y%m%dT%H%M%SZ")

      dir =
        Path.join(
          ctx.config.runs_dir,
          "triage-#{@triage["record_id"]}-#{stamp}-#{binary_part(run_id, 0, 8)}"
        )

      File.mkdir_p!(Path.join(dir, "verdict.token"))
    end

    result =
      try do
        TriageRun.execute(ctx.config, @triage, "mkreyman/fixture", run_id: run_id)
      after
        restore.()
      end

    assert {:incomplete, "no_verdict_written", detail} = result.outcome
    assert detail =~ "could not be prepared"
    # The session never started, so nothing was launched to produce anything.
    refute File.exists?(Path.join(ctx.state, "argv"))

    assert {:ok, %{"status" => "incomplete:no_verdict_written"}} =
             RunStateRead.read(result.run_dir)
  end

  test "every reason this module reports is one the vendored contract publishes" do
    # The compile-time raise is the real guard; this is what says so where a reader looks, and it
    # fails if the contract is vendored with a reason renamed out from under the code.
    assert "checkout_unreadable" in TriageRun.incomplete_reasons()
    assert length(TriageRun.incomplete_reasons()) == 5
  end

  test "a verdict the session stated survives the session monitor dying", ctx do
    # Session.run/1 exits when the process supervising the session dies. The run's own guard would
    # then report {:error, _} without ever looking in the run directory — discarding a verdict the
    # session had already stated and linked into place, which is the one thing triage exists to
    # produce. The session hangs after stating it, so the kill lands while it is still running.
    restore =
      fake_env!(ctx.state, [
        {"FAKE_CLAUDE_MODE", "hang"},
        {"FAKE_VERDICT", Jason.encode!(@verdict)}
      ])

    task =
      Task.async(fn -> TriageRun.execute(ctx.config, @triage, "mkreyman/fixture", []) end)

    try do
      wait_for(fn ->
        Path.wildcard(Path.join(ctx.config.runs_dir, "triage-*/verdict.json")) != []
      end)

      Process.exit(wait_for_session(), :kill)
      result = Task.await(task, 30_000)

      assert {:verdict, verdict} = result.outcome
      assert verdict["outcome"] == "escalate"
      # And the session's own report is not invented from a crash.
      assert result.session == nil
      assert {:ok, %{"status" => "verdict"}} = RunStateRead.read(result.run_dir)
    after
      restore.()
    end
  end

  defp wait_for(check, attempts \\ 300) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(20) && wait_for(check, attempts - 1)
    end
  end

  # The GenServer Session.run/1 monitors: unnamed, so it is found by what it was started as.
  defp wait_for_session do
    pid =
      Enum.find(Process.list(), fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            match?({LoopctlRunner.Session, :init, 1}, dict[:"$initial_call"])

          _ ->
            false
        end
      end)

    if pid, do: pid, else: Process.sleep(20) && wait_for_session()
  end

  test "a run directory that disappears is still reported, never raised out of the run", ctx do
    # The session removes its own run directory, so the closing state write raises. Unguarded that
    # raise leaves state.json at "running" with this BEAM's live owner recorded — the one
    # combination Reaper.orphan?/1 never cleans up — and takes the result with it.
    result = execute(ctx, [{"FAKE_CLAUDE_MODE", "delete_run_dir"}])

    assert {:incomplete, "no_verdict_written", _} = result.outcome
    refute File.exists?(Path.join(result.run_dir, "state.json"))
  end

  test "the run leaves a trace naming what it produced", ctx do
    result =
      execute(ctx, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}])

    {:ok, events} = LoopctlRunner.Trace.read(Path.join(result.run_dir, "trace.ndjson"))
    types = Enum.map(events, & &1["type"])

    assert "triage.started" in types
    assert "triage.finished" in types
    [finished] = Enum.filter(events, &(&1["type"] == "triage.finished"))
    assert finished["data"]["outcome"] == "verdict"
  end
end

defmodule RunStateRead do
  def read(run_dir), do: LoopctlRunner.RunState.read(run_dir)
end
