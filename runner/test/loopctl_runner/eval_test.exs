defmodule LoopctlRunner.EvalTest do
  @moduledoc """
  US-48.10, the runner half of the eval harness: the committed case sets load, run OFFLINE through
  the runner's own launcher and session path on the suite's fake CLI, and write results in the
  format loopctl replays; a case whose expectation cannot hold fails the run naming it; a case
  whose fixture lies outside `eval/fixtures` refuses the run before anything runs; and nothing
  opens a socket.

  Async: every input the harness reads is passed in — the eval directory, results and scratch
  directories, the launcher, the fake CLI's directory (put on the SESSION's PATH through the
  repo's session environment, never this BEAM's), the grant and projects directories — so no
  test changes anything another test reads.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import LoopctlRunner.TestSupport

  alias LoopctlRunner.{Contract, Eval, Templates}
  alias LoopctlRunner.Eval.{Case, Fixture, Judge, Result}

  @moduletag timeout: 180_000

  @eval_dir Path.expand("../../eval", __DIR__)
  @pinned "6275d38f062136ea998174995850b1bf3be1ba86"

  setup do
    root = tmp_dir!("eval")
    {:ok, root: root, opts: opts(root)}
  end

  defp opts(root, overrides \\ []) do
    Keyword.merge(
      [
        eval_dir: @eval_dir,
        results_dir: Path.join(root, "results"),
        scratch_dir: Path.join(root, "scratch"),
        launcher: headless_launcher(),
        cli_dir: fake_bin_dir(),
        grant_dir: Path.join(root, "grants"),
        projects_dir: Path.join(root, "projects"),
        machine: "testbox (offline: fake CLI)"
      ],
      overrides
    )
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  # An eval directory of the test's own: the committed fixture, and the cases it is given.
  defp own_eval_dir!(root, cases) do
    dir = Path.join(root, "eval")
    File.mkdir_p!(Path.join(dir, "fixtures"))

    File.cp!(
      Path.join(@eval_dir, "fixtures/tiny_app.json"),
      Path.join(dir, "fixtures/tiny_app.json")
    )

    for {set, name, case_map, offline} <- cases do
      File.mkdir_p!(Path.join(dir, set))
      File.write!(Path.join([dir, set, name <> ".json"]), Jason.encode!(case_map))

      if offline do
        File.mkdir_p!(Path.join([dir, "offline", set]))
        File.write!(Path.join([dir, "offline", set, name <> ".json"]), Jason.encode!(offline))
      end
    end

    dir
  end

  defp seed(set, name), do: read_json!(Path.join([@eval_dir, set, name <> ".json"]))

  defp seed_offline(set, name),
    do: read_json!(Path.join([@eval_dir, "offline", set, name <> ".json"]))

  describe "the committed case sets" do
    test "every case loads against the case schema, and the seed sets are the size AC-48.10.4 asks",
         ctx do
      sizes =
        for set <- ["triage@1", "reply_draft@1", "implement@1", "verify@1"], into: %{} do
          assert {:ok, cases} = Case.load_all(set, @eval_dir, ctx.root)
          {set, length(cases)}
        end

      assert sizes["triage@1"] >= 5
      assert sizes["reply_draft@1"] >= 5
      assert sizes["implement@1"] >= 3
      assert sizes["verify@1"] >= 3
    end

    # A template with no cases is one no eval run can score and no tuning run can be held to: its
    # `eval_set` is empty, so a proposed revision of it beats nothing. spec_tuner@1 is the one
    # exception, because what scores a tuning run is the critic over its TARGET's cases.
    test "every template this runner holds, but spec_tuner, has a case set of its own", ctx do
      sets =
        for %{id: id, version: version} <- Templates.all(),
            id != "spec_tuner",
            do: "#{id}@#{version}"

      assert "verify@1" in sets

      for set <- sets do
        assert {:ok, [_ | _]} = Case.load_all(set, @eval_dir, ctx.root),
               "#{set} has no committed eval cases"
      end
    end

    test "every case is pinned to a commit the fixture builds to, deterministically", ctx do
      {:ok, manifest} = Fixture.load(Path.join(@eval_dir, "fixtures/tiny_app.json"))
      assert {:ok, %{head: @pinned}} = Fixture.build(manifest, Path.join(ctx.root, "a"))
      assert {:ok, %{head: @pinned}} = Fixture.build(manifest, Path.join(ctx.root, "b"))

      for set <- ["triage@1", "reply_draft@1", "implement@1"] do
        {:ok, cases} = Case.load_all(set, @eval_dir, ctx.root)
        assert Enum.all?(cases, &(&1.commit == @pinned))
      end
    end

    # verify@1 judges a pull request, so its fixture has history ABOVE a case's base: the base is
    # the case's commit and the head its dispatch names. tiny_app_pr's first two commits are
    # tiny_app's, byte for byte, so the defect the other sets judge is the same commit here.
    test "the verify set's fixture builds deterministically, and holds every head a case names",
         ctx do
      {:ok, manifest} = Fixture.load(Path.join(@eval_dir, "fixtures/tiny_app_pr.json"))
      assert {:ok, built} = Fixture.build(manifest, Path.join(ctx.root, "pr_a"))
      assert {:ok, %{head: head}} = Fixture.build(manifest, Path.join(ctx.root, "pr_b"))
      assert built.head == head

      # Under the commit gate git exports GIT_DIR to the hook, which would point -C at the
      # outer repository; clear it as every git call in lib/ does.
      {log, 0} =
        System.cmd("git", ["-C", built.path, "rev-list", "HEAD"],
          env: Enum.map(LoopctlRunner.Worktree.repo_locating_env(), &{&1, nil})
        )

      history = String.split(log, "\n", trim: true)
      assert @pinned in history

      {:ok, cases} = Case.load_all("verify@1", @eval_dir, ctx.root)

      for c <- cases, c.name != "v04_head_moved" do
        assert c.input["verify"]["head_sha"] in history, c.name
        refute c.input["verify"]["head_sha"] == c.commit, "#{c.name} judges an empty diff"
      end

      moved = Enum.find(cases, &(&1.name == "v04_head_moved"))
      refute moved.input["verify"]["head_sha"] in history
    end

    test "every report is fenced the way loopctl fences untrusted text, with a nonce of its own",
         ctx do
      for set <- ["triage@1", "reply_draft@1"] do
        {:ok, cases} = Case.load_all(set, @eval_dir, ctx.root)

        for %{input: %{"triage" => %{"untrusted" => text}}, name: name} <- cases do
          [open | rest] = String.split(text, "\n")
          close = List.last(rest)

          assert [_, nonce] =
                   Regex.run(
                     ~r/\A⟦UNTRUSTED DATA field=reported_issue nonce=([0-9a-f]{12})⟧\z/,
                     open
                   ),
                 "#{name}: #{open}"

          assert close == "⟦END UNTRUSTED DATA field=reported_issue nonce=#{nonce}⟧"
          data = rest |> Enum.drop(1) |> Enum.drop(-1)
          assert Enum.all?(data, &String.starts_with?(&1, "| ")), name
        end
      end
    end
  end

  describe "the case schema" do
    setup ctx do
      {:ok, good: seed("triage@1", "t01_clear_defect_story"), root: ctx.root}
    end

    defp load_one(root, set, case_map) do
      dir = own_eval_dir!(root, [{set, "c", case_map, nil}])
      Case.load(Path.join([dir, set, "c.json"]), dir, Path.join(root, "scratch"))
    end

    test "a well-formed case loads", ctx do
      assert {:ok, %{name: "c", commit: @pinned}} = load_one(ctx.root, "triage@1", ctx.good)
    end

    test "a missing expectation is refused", ctx do
      bad = update_in(ctx.good, ["expectations"], &Map.delete(&1, "forbidden"))
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "forbidden"
    end

    test "an unknown key is refused", ctx do
      assert {:error, reason} = load_one(ctx.root, "triage@1", Map.put(ctx.good, "extra", 1))
      assert reason =~ "extra"
    end

    test "an input that is not a RunnerDispatch is refused", ctx do
      bad = update_in(ctx.good, ["input"], &Map.delete(&1, "claim_epoch"))
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "not a RunnerDispatch"
    end

    test "an input of another kind than the spec's template is refused", ctx do
      bad = put_in(ctx.good, ["input", "kind"], "reply_draft")
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "is not triage"
    end

    test "a case outside its spec's directory is refused", ctx do
      assert {:error, reason} = load_one(ctx.root, "reply_draft@1", ctx.good)
      assert reason =~ "must live in eval/triage@1/"
    end

    test "a :judge's expectations on a :draft case are refused", ctx do
      draft = seed("reply_draft@1", "r01_acknowledge_defect")
      bad = put_in(draft, ["expectations", "lens_agreement"], true)
      assert {:error, reason} = load_one(ctx.root, "reply_draft@1", bad)
      assert reason =~ "lens_agreement is a :judge's"
    end

    test "a screen loopctl does not replay the spec through is refused", ctx do
      bad = put_in(ctx.good, ["expectations", "screens"], ["gate_a:agent_escalated"])
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "is not a screen loopctl replays triage through"

      draft = seed("reply_draft@1", "r01_acknowledge_defect")
      bad = put_in(draft, ["expectations", "screens"], ["gate_a"])
      assert {:error, _} = load_one(ctx.root, "reply_draft@1", bad)

      build = seed("implement@1", "i01_fix_total")
      bad = put_in(build, ["expectations", "screens"], ["gate_a"])
      assert {:error, _} = load_one(ctx.root, "implement@1", bad)
    end

    # Contract 1.30.0 took story_id out of the schema's required; the case's input is still held
    # to what loopctl would send, so a non-story-less input with no story is no case.
    test "an input with no story_id is refused, though the schema now admits it", ctx do
      bad = update_in(ctx.good, ["input"], &Map.delete(&1, "story_id"))
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "a triage dispatch must carry story_id"
    end

    test "a forbidden pattern that does not compile is refused", ctx do
      bad = put_in(ctx.good, ["expectations", "forbidden"], ["(unclosed"])
      assert {:error, reason} = load_one(ctx.root, "triage@1", bad)
      assert reason =~ "is not a regex"
    end
  end

  # US-48.13: the spec_tuner@1 critic scores a PROPOSED template by transforming each case's
  # rendered prompt. A transform that refuses must cost the case its pass on both run paths —
  # never fall back to the prompt as it was, which would score the current template as proposed.
  describe "run_cases/2's :prompt_transform" do
    for {set, name} <- [{"triage@1", "t01_clear_defect_story"}, {"implement@1", "i01_fix_total"}] do
      test "#{set}: a refusing transform fails the case, an identity one does not", ctx do
        {:ok, cases} = Case.load_all(unquote(set), @eval_dir, ctx.root)
        cases = Enum.filter(cases, &(&1.name == unquote(name)))
        assert [_] = cases

        refusing = opts(ctx.root, prompt_transform: fn _ -> {:error, "no such line"} end)
        assert {:ok, [refused]} = Eval.run_cases(cases, refusing)
        refute refused.passed, Eval.table([refused])

        identity =
          opts(Path.join(ctx.root, "identity"), prompt_transform: fn prompt -> {:ok, prompt} end)

        assert {:ok, [kept]} = Eval.run_cases(cases, identity)
        assert kept.passed, Eval.table([kept])
      end
    end
  end

  # US-48.13: a spec_tuner@1 critic's sessions run inside the tuning dispatch's time, so every one
  # must be gone by its deadline_at. A case whose WHOLE session no longer fits (less kill grace and
  # clock-skew margin) is not started, and the run stops there.
  describe "run_cases/2's :deadline_at" do
    setup ctx do
      {:ok, drafts} = Case.load_all("reply_draft@1", @eval_dir, ctx.root)
      {:ok, triages} = Case.load_all("triage@1", @eval_dir, ctx.root)
      draft = Enum.find(drafts, &(&1.name == "r01_acknowledge_defect"))
      triage = Enum.find(triages, &(&1.name == "t01_clear_defect_story"))
      # The fixed budgets the arithmetic below reads.
      assert draft.input["wall_clock_seconds"] == 600
      assert triage.input["wall_clock_seconds"] == 900
      # Real time, because the sessions' own deadline checks read the real clock; held still for
      # the harness's budget so the arithmetic below is exact (the fake CLI takes about no time).
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {:ok, draft: draft, triage: triage, now: now}
    end

    # 10 s kill grace (the eval's config default) + 5 s clock-skew margin, then `left` seconds.
    defp deadline(now, left), do: DateTime.add(now, 15 + left, :second)

    test "stops before the first case that cannot finish, having run every one before it", ctx do
      opts =
        opts(ctx.root,
          now: fn -> ctx.now end,
          keep_scratch: true,
          deadline_at: deadline(ctx.now, 750)
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:ran, Eval.run_cases([ctx.draft, ctx.triage], opts)})
        end)

      assert_received {:ran, {:error, reason}}
      assert reason =~ "the eval stops before case triage@1/t01_clear_defect_story"
      assert reason =~ "leaves 750s"
      assert reason =~ "less than its 900s session"
      assert log =~ "the eval stops before case triage@1/t01_clear_defect_story"

      # The draft fit (600 of 750) and ran, bound by the run's deadline rather than its own none.
      assert File.exists?(
               Path.join([ctx.root, "results", "reply_draft@1", "r01_acknowledge_defect.json"])
             )

      refute File.exists?(
               Path.join([ctx.root, "results", "triage@1", "t01_clear_defect_story.json"])
             )

      [trace] =
        Path.wildcard(
          Path.join([
            ctx.root,
            "scratch",
            "cases",
            "reply_draft@1",
            "*",
            "runs",
            "*",
            "trace.ndjson"
          ])
        )

      {:ok, events} = LoopctlRunner.Trace.read(trace)
      started = Enum.find(events, &(&1["type"] == "session.started"))
      assert started["data"]["deadline_at"] == DateTime.to_iso8601(deadline(ctx.now, 750))
    end

    test "a case that fits exactly runs, and no deadline bounds nothing", ctx do
      fits = opts(ctx.root, now: fn -> ctx.now end, deadline_at: deadline(ctx.now, 600))
      assert {:ok, [%{passed: true}]} = Eval.run_cases([ctx.draft], fits)

      unbounded = opts(Path.join(ctx.root, "unbounded"), now: fn -> ctx.now end)

      assert {:ok, [%{passed: true}, %{passed: true}]} =
               Eval.run_cases([ctx.draft, ctx.triage], unbounded)
    end
  end

  describe "the scratch directory" do
    test "a pre-existing --scratch-dir keeps what it held: only the run's own subdirectory goes",
         ctx do
      scratch = Path.join(ctx.root, "operator-scratch")
      File.mkdir_p!(Path.join(scratch, "keep-me"))
      File.write!(Path.join(scratch, "precious.txt"), "do not delete")
      File.write!(Path.join([scratch, "keep-me", "nested.txt"]), "nor this")

      capture_io(fn ->
        Mix.Tasks.LoopctlRunner.Eval.run(
          task_args(ctx.root, "reply_draft@1", scratch_dir: scratch)
        )
      end)

      assert File.read!(Path.join(scratch, "precious.txt")) == "do not delete"
      assert File.read!(Path.join([scratch, "keep-me", "nested.txt"])) == "nor this"
      # And the harness's own subdirectory is gone: the directory holds exactly what it held.
      assert Enum.sort(File.ls!(scratch)) == ["keep-me", "precious.txt"]
    end

    test "a pre-existing empty --scratch-dir survives the run too", ctx do
      scratch = Path.join(ctx.root, "empty-scratch")
      File.mkdir_p!(scratch)

      assert {:ok, [_ | _]} = Eval.run("reply_draft@1", opts(ctx.root, scratch_dir: scratch))
      assert File.ls!(scratch) == []
    end

    test "a scratch directory the harness created is removed whole after the run", ctx do
      scratch = Path.join(ctx.root, "made-by-the-harness")

      assert {:ok, [_ | _]} = Eval.run("reply_draft@1", opts(ctx.root, scratch_dir: scratch))
      refute File.exists?(scratch)
    end

    test "the missing parents of a --scratch-dir the harness created go with it", ctx do
      scratch = Path.join([ctx.root, "made", "by", "the-harness"])

      assert {:ok, [_ | _]} = Eval.run("reply_draft@1", opts(ctx.root, scratch_dir: scratch))
      refute File.exists?(Path.join(ctx.root, "made"))
      assert File.exists?(ctx.root)
    end

    test "--keep-scratch prints the directory the run actually used", ctx do
      scratch = Path.join(ctx.root, "kept-scratch")
      File.mkdir_p!(scratch)

      output =
        capture_io(fn ->
          Mix.Tasks.LoopctlRunner.Eval.run(
            task_args(ctx.root, "reply_draft@1", scratch_dir: scratch) ++ ["--keep-scratch"]
          )
        end)

      assert [used] = File.ls!(scratch)
      assert used =~ ~r/\Aloopctl-runner-eval-[0-9a-f]{8}\z/
      assert output =~ "scratch kept at #{Path.join(scratch, used)}"
      assert File.dir?(Path.join([scratch, used, "fixtures"]))
    end

    test "a fixture in the --scratch-dir the operator named resolves, not only in the run's own",
         ctx do
      scratch = Path.join(ctx.root, "operator-fixtures")
      File.mkdir_p!(scratch)

      File.cp!(
        Path.join(@eval_dir, "fixtures/tiny_app.json"),
        Path.join(scratch, "tiny_app.json")
      )

      case_map =
        put_in(
          seed("reply_draft@1", "r01_acknowledge_defect"),
          ["fixture", "repo"],
          Path.join(scratch, "tiny_app.json")
        )

      offline = seed_offline("reply_draft@1", "r01_acknowledge_defect")
      eval_dir = own_eval_dir!(ctx.root, [{"reply_draft@1", "r01", case_map, offline}])

      assert {:ok, [%{passed: true}]} =
               Eval.run("reply_draft@1", opts(ctx.root, scratch_dir: scratch, eval_dir: eval_dir))
    end
  end

  describe "an offline run (TC-48.10.1)" do
    test "the triage set runs through the fake CLI, passes, and prints its table", ctx do
      output =
        capture_io(fn ->
          Mix.Tasks.LoopctlRunner.Eval.run(task_args(ctx.root, "triage@1"))
        end)

      {:ok, cases} = Case.load_all("triage@1", @eval_dir, ctx.root)

      for c <- cases do
        assert output =~ ~r/triage@1\/#{c.name}\s+PASS/
      end

      assert output =~ "#{length(cases)} of #{length(cases)} cases passed"
    end

    test "the reply_draft, implement and verify sets pass offline too", ctx do
      for set <- ["reply_draft@1", "implement@1", "verify@1"] do
        assert {:ok, results} = Eval.run(set, ctx.opts)
        assert Enum.all?(results, & &1.passed), Eval.table(results)
      end
    end

    test "starts no Control and links nothing that opens a socket", ctx do
      assert {:ok, [_ | _]} = Eval.run("reply_draft@1", ctx.opts)

      refute Enum.any?(Process.list(), fn pid ->
               match?(
                 {:dictionary, %{"$initial_call": {LoopctlRunner.Control, _, _}}},
                 dictionary(pid)
               )
             end)

      # Nothing in the harness calls anything that connects: not Control, not the socket client,
      # not a raw socket.
      for module <- [Eval, Case, Fixture, Judge, Result, Mix.Tasks.LoopctlRunner.Eval] do
        {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
        called = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        for forbidden <- [LoopctlRunner.Control, Slipstream, :gen_tcp, :ssl, Mint.HTTP] do
          refute forbidden in called, "#{inspect(module)} calls #{inspect(forbidden)}"
        end
      end
    end
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> {:dictionary, Map.new(dict)}
      nil -> nil
    end
  end

  defp task_args(root, set, extra \\ []) do
    o = opts(root, extra)

    [
      set,
      "--eval-dir",
      o[:eval_dir],
      "--results-dir",
      o[:results_dir],
      "--scratch-dir",
      o[:scratch_dir],
      "--launcher",
      o[:launcher],
      "--cli",
      o[:cli_dir],
      "--grant-dir",
      o[:grant_dir],
      "--projects-dir",
      o[:projects_dir]
    ]
  end

  describe "a failing case (TC-48.10.2)" do
    test "fails the run, exits non-zero, and names the case", ctx do
      impossible =
        put_in(seed("triage@1", "t01_clear_defect_story"), ["expectations", "outcomes_allowed"], [
          "reject"
        ])

      offline = seed_offline("triage@1", "t01_clear_defect_story")

      dir =
        own_eval_dir!(ctx.root, [
          {"triage@1", "cannot_hold", impossible, offline},
          {"triage@1", "holds", seed("triage@1", "t01_clear_defect_story"), offline}
        ])

      output =
        capture_io(fn ->
          error =
            assert_raise Mix.Error, fn ->
              Mix.Tasks.LoopctlRunner.Eval.run(task_args(ctx.root, "triage@1", eval_dir: dir))
            end

          assert error.message =~ "1 of 2 eval cases failed: triage@1/cannot_hold"
          refute error.message =~ "triage@1/holds"
        end)

      assert output =~
               ~r/triage@1\/cannot_hold\s+FAIL\s+story\s+outcome: outcome story is not one of reject/

      assert output =~ ~r/triage@1\/holds\s+PASS/
    end
  end

  describe "AC-48.10.5: a fixture outside eval/fixtures" do
    test "refuses the whole run before anything runs", ctx do
      outside =
        put_in(seed("triage@1", "t01_clear_defect_story"), ["fixture", "repo"], "../../loopctl")

      dir =
        own_eval_dir!(ctx.root, [
          {"triage@1", "a_good_one", seed("triage@1", "t01_clear_defect_story"), nil},
          {"triage@1", "z_outside", outside, nil}
        ])

      assert {:error, reason} = Eval.run("triage@1", opts(ctx.root, eval_dir: dir))
      assert reason =~ "z_outside.json"
      assert reason =~ "outside"
      # Not even the good case ran: no result was written, and nothing was built.
      refute File.exists?(Path.join(ctx.root, "results"))

      error =
        assert_raise Mix.Error, fn ->
          Mix.Tasks.LoopctlRunner.Eval.run(task_args(ctx.root, "triage@1", eval_dir: dir))
        end

      assert error.message =~ "eval refused to run, nothing ran"
    end

    test "refuses an absolute path to a real checkout", ctx do
      assert {:error, reason} =
               Fixture.resolve(File.cwd!(), @eval_dir, Path.join(ctx.root, "scratch"))

      assert reason =~ "outside"
    end

    test "refuses a symlink inside eval/fixtures that points elsewhere", ctx do
      dir = own_eval_dir!(ctx.root, [])
      File.ln_s!(File.cwd!(), Path.join(dir, "fixtures/escape"))

      assert {:error, reason} =
               Fixture.resolve("fixtures/escape/mix.exs", dir, Path.join(ctx.root, "scratch"))

      assert reason =~ "symlink"
    end

    test "accepts a manifest under eval/fixtures or the scratch directory", ctx do
      scratch = Path.join(ctx.root, "scratch")
      assert {:ok, _} = Fixture.resolve("fixtures/tiny_app.json", @eval_dir, scratch)
      assert {:ok, _} = Fixture.resolve(Path.join(scratch, "f.json"), @eval_dir, scratch)
    end
  end

  describe "the result file (the shared format)" do
    setup ctx do
      {:ok, results} = Eval.run("triage@1", ctx.opts)
      {:ok, drafts} = Eval.run("reply_draft@1", ctx.opts)
      {:ok, builds} = Eval.run("implement@1", ctx.opts)
      {:ok, results: results ++ drafts ++ builds}
    end

    test "carries exactly the shared keys, the machine, and the case's screens", ctx do
      for r <- ctx.results do
        result = read_json!(r.result_path)
        assert Enum.sort(Map.keys(result)) == Enum.sort(Result.keys())
        assert result["format"] == 1
        assert result["machine"] == "testbox (offline: fake CLI)"
        assert {:ok, _, 0} = DateTime.from_iso8601(result["recorded_at"])
        assert r.result_path == Path.join([ctx.root, "results", r.set, r.name <> ".json"])

        c = seed(r.set, r.name)
        assert result["spec"] == %{"id" => c["spec"], "version" => c["version"]}
        assert result["case"] == r.name
        assert result["input"] == c["input"]
        assert result["expected"] == %{"screens" => c["expectations"]["screens"]}
      end
    end

    test "a triage result's message is a full RunnerTriageVerdictMessage", ctx do
      result = read_json!(path(ctx, "triage@1", "t01_clear_defect_story"))
      assert result["event"] == "triage_verdict"
      assert result["runner_outcome"] == "verdict"
      message = result["message"]
      assert Contract.validate("RunnerTriageVerdictMessage", message) == :ok
      assert message["dispatch_id"] == result["input"]["dispatch_id"]
      assert message["verdict"]["outcome"] == "story"
      assert length(message["lens_verdicts"]) == 3
    end

    test "a reply_draft result's message is a RunnerAgentResultMessage naming its spec", ctx do
      result = read_json!(path(ctx, "reply_draft@1", "r01_acknowledge_defect"))
      assert result["event"] == "agent_result"
      assert result["runner_outcome"] == "agent_result"
      assert Contract.validate("RunnerAgentResultMessage", result["message"]) == :ok
      assert result["message"]["spec"] == %{"id" => "reply_draft", "version" => 1}
      assert result["message"]["result"]["body"] =~ "Thanks for the report"
    end

    test "an implement result's message is the RunnerSessionEnded the run's end reports", ctx do
      completed = read_json!(path(ctx, "implement@1", "i01_fix_total"))
      assert completed["event"] == "session_ended"
      assert completed["runner_outcome"] == "succeeded"
      assert Contract.validate("RunnerSessionEnded", completed["message"]) == :ok
      assert completed["message"]["reason"] == "completed"

      assert read_json!(path(ctx, "implement@1", "i02_turn_budget_exhausted"))["message"][
               "reason"
             ] ==
               "max_turns_exceeded"

      escalated = read_json!(path(ctx, "implement@1", "i03_contradictory_story"))
      assert escalated["runner_outcome"] == "escalated"
      assert escalated["message"]["reason"] == "completed"
    end
  end

  defp path(ctx, set, name),
    do: Enum.find(ctx.results, &(&1.set == set and &1.name == name)).result_path

  describe "AC-48.10.5: an eval session loads no MCP server" do
    @isolation LoopctlRunner.Session.mcp_isolation("/scratch/mcp-none.json")
    @story %LoopctlRunner.Story{
      id: "s1",
      repo: "fixture",
      repo_path: "/tmp",
      base: "master",
      branch: "loop/s1",
      prompt: "do the thing",
      wall_clock_s: 60,
      max_turns: 5
    }

    # Each template's builder, once as the live path calls it and once as the eval does.
    defp builders do
      alias LoopctlRunner.{ReplyDraftPrompt, Session, TriagePrompt, TriageTools}

      [
        {"implement", Session.claude_args(@story, "sid"),
         Session.claude_args(@story, "sid", Session.escalation_prompt(), @isolation)},
        {"triage",
         TriageTools.claude_args("p", "sid", TriagePrompt.system_prompt(), max_turns: 5),
         TriageTools.claude_args("p", "sid", TriagePrompt.system_prompt(),
           max_turns: 5,
           mcp_args: @isolation
         )},
        {"reply_draft", ReplyDraftPrompt.claude_args("p", "sid", max_turns: 5),
         ReplyDraftPrompt.claude_args("p", "sid", max_turns: 5, mcp_args: @isolation)}
      ]
    end

    test "a dispatched session's argv is unchanged: no MCP flag, and the default is no option at all" do
      alias LoopctlRunner.{ReplyDraftPrompt, Session, TriagePrompt, TriageTools}

      for {name, live, _eval} <- builders() do
        refute "--strict-mcp-config" in live, name
        refute "--mcp-config" in live, name
      end

      assert Session.claude_args(@story, "sid") ==
               Session.claude_args(@story, "sid", Session.escalation_prompt(), [])

      assert TriageTools.claude_args("p", "sid", TriagePrompt.system_prompt(), max_turns: 5) ==
               TriageTools.claude_args("p", "sid", TriagePrompt.system_prompt(),
                 max_turns: 5,
                 mcp_args: []
               )

      assert ReplyDraftPrompt.claude_args("p", "sid", max_turns: 5) ==
               ReplyDraftPrompt.claude_args("p", "sid", max_turns: 5, mcp_args: [])
    end

    test "the isolation is an exact insertion before the system prompt, and changes nothing else" do
      for {name, live, eval} <- builders() do
        assert eval -- @isolation == live, name
        at = Enum.find_index(eval, &(&1 == "--strict-mcp-config"))
        assert Enum.slice(eval, at, 4) == @isolation ++ ["--append-system-prompt"], name
      end
    end

    test "every session an eval run launches gets --strict-mcp-config and an empty MCP config",
         ctx do
      for set <- ["triage@1", "reply_draft@1", "implement@1"] do
        scratch = Path.join(ctx.root, "kept-" <> set)

        assert {:ok, results} =
                 Eval.run(set, opts(ctx.root, scratch_dir: scratch, keep_scratch: true))

        for r <- results do
          # What the fake CLI received through the real launcher, one argument per line.
          argv =
            [scratch, "cases", set, r.name, "fake", "argv"]
            |> Path.join()
            |> File.read!()
            |> String.split("\n")

          assert "--strict-mcp-config" in argv, "#{set}/#{r.name}"
          config = Enum.at(argv, Enum.find_index(argv, &(&1 == "--mcp-config")) + 1)
          assert config == Path.join(scratch, "mcp-none.json")
          assert read_json!(config) == %{"mcpServers" => %{}}
        end
      end
    end
  end

  describe "the judge" do
    @verdict %{
      "dispatch_id" => "e7a11010-0000-4000-8000-000000000001",
      "claim_epoch" => 1,
      "verdict" => %{
        "outcome" => "escalate",
        "confidence" => "high",
        "escalation_reasons" => ["a sentence"]
      },
      "lens_verdicts" => [
        %{
          "lens" => "analyst",
          "outcome" => "escalate",
          "confidence" => "high",
          "escalation_reasons" => ["workflow_change_not_defect_fix"]
        },
        %{"lens" => "architect", "outcome" => "story", "confidence" => "high"},
        %{"lens" => "engineer", "outcome" => "escalate", "confidence" => "high"}
      ]
    }

    defp expect(overrides) do
      Map.merge(
        %{
          "schema_valid" => true,
          "outcomes_allowed" => ["escalate"],
          "escalation_codes" => [],
          "lens_agreement" => nil,
          "forbidden" => [],
          "screens" => [],
          "rubric" => nil
        },
        overrides
      )
    end

    defp failed(checks), do: for({name, {:fail, _}} <- checks, do: name)

    test "holds every expectation that the message meets" do
      checks =
        Judge.judge(
          expect(%{
            "escalation_codes" => ["workflow_change_not_defect_fix"],
            "lens_agreement" => false
          }),
          [~r/rm -rf/],
          "triage_verdict",
          @verdict,
          "verdict"
        )

      assert Judge.passed?(checks)
    end

    test "names each expectation the message breaks" do
      checks =
        Judge.judge(
          expect(%{
            "outcomes_allowed" => ["story"],
            "escalation_codes" => ["inverts_or_removes_deliberate_behaviour"],
            "lens_agreement" => true
          }),
          [~r/sentence/],
          "triage_verdict",
          @verdict,
          "verdict"
        )

      assert failed(checks) == ["outcome", "escalation_codes", "lens_agreement", "forbidden"]
    end

    test "a missing message fails schema_valid, and a message that breaks the contract does too" do
      assert "schema_valid" in failed(
               Judge.judge(expect(%{}), [], "triage_verdict", nil, "failed")
             )

      both = Map.put(@verdict, "incomplete", "no_verdict_written")

      assert "schema_valid" in failed(
               Judge.judge(expect(%{}), [], "triage_verdict", both, "verdict")
             )
    end

    test "a forbidden pattern judges what the session wrote, never the runner's envelope" do
      uuid = ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

      assert Judge.passed?(
               Judge.judge(expect(%{}), [uuid], "triage_verdict", @verdict, "verdict")
             )

      leaked =
        put_in(@verdict, ["verdict", "escalation_reasons"], ["see #{@verdict["dispatch_id"]}"])

      assert "forbidden" in failed(
               Judge.judge(expect(%{}), [uuid], "triage_verdict", leaked, "verdict")
             )
    end

    test "a verify result's outcome is its verdict, so a pass and a reject are told apart" do
      message = fn verdict ->
        %{
          "spec" => %{"id" => "verify", "version" => 1},
          "result" => %{"verdict" => verdict, "findings" => [], "head_sha" => @pinned}
        }
      end

      assert Judge.outcome("agent_result", message.("pass"), "agent_result") == "pass"
      assert Judge.outcome("agent_result", message.("reject"), "agent_result") == "reject"

      reply = %{"spec" => %{"id" => "reply_draft", "version" => 1}, "result" => %{"body" => "x"}}
      assert Judge.outcome("agent_result", reply, "agent_result") == "agent_result"
    end

    test "a refused dispatch is its own outcome" do
      assert Judge.outcome("agent_result", nil, "refused:repo_not_allowed") ==
               "refused:repo_not_allowed"
    end
  end
end
