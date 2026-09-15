defmodule LoopctlRunner.TriageRunTest do
  # Mutates PATH and FAKE_* in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{TriageRun, TriageVerdict}
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

    assert argv =~ "--tools\nRead,Glob,Grep,Agent,Bash\n"
    refute argv =~ "Write(./**)"
    refute argv =~ "Edit(./**)"
    assert argv =~ "--agents\n"
    # And it ran in the checkout itself: a triage run has no worktree.
    assert File.read!(Path.join(ctx.state, "cwd")) |> String.trim() =~ "repo"
    refute File.dir?(Path.join([ctx.root, "repo", ".claude", "worktrees"]))
    assert result.session.exit_status == 0
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
