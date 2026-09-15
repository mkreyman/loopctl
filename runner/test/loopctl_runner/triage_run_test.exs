defmodule LoopctlRunner.TriageRunTest do
  # Mutates PATH and FAKE_* in the OS environment, which every spawned process inherits.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{TriageRun, TriageVerdict}
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  @verdict %{"outcome" => "escalate", "confidence" => "high", "missing_information" => ["what?"]}

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

  test "a repo with no local checkout fails before anything runs", ctx do
    restore = fake_env!(ctx.state, [{"FAKE_CLAUDE_MODE", "stream"}])

    result =
      try do
        TriageRun.execute(ctx.config, @triage, "someone/absent")
      after
        restore.()
      end

    assert {:error, reason} = result.outcome
    assert reason =~ "no local checkout"
    assert result.session == nil
    refute File.exists?(Path.join(ctx.state, "argv"))
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
