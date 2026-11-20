defmodule LoopctlRunner.SelectionReplayTest do
  @moduledoc """
  Contract 1.32.0's `selection_replay`, attached by the RUNNER to a verify@1 pass on a change to
  selection code (`LoopctlRunner.SelectionReplay`), end to end on the verify path: a local
  origin, the fake CLI as the session, and a fake replay script committed on the base. The
  fake script records its argv and prints what the product directory holds, so every input is
  this test's data; nothing reads or writes this BEAM's environment.
  """

  use ExUnit.Case, async: true

  alias LoopctlRunner.{ProcessGroup, RunState, SelectionReplay, Session, Templates, TriageRun}

  import LoopctlRunner.TestSupport

  @moduletag timeout: 120_000

  @story_id "2e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6c"

  # The base's replay script. It reads the product directory for what to do: `sleep` holds the
  # seconds to wait first, `replay.out` what to print; `argv` records how it was called.
  # `unmarked` starts a child without the marker (as an Apple binary reads on macOS), its pid in
  # `unmarked.pid`; `extra` prints a second stdout line after the result, as a process of the
  # head's code reaching the stream would.
  @base_script """
  import os, pathlib, subprocess, sys, time
  args = sys.argv[1:]
  repo = pathlib.Path(args[args.index("--repo") + 1])
  if (repo / "unmarked").exists():
      env = {k: v for k, v in os.environ.items() if k != "LOOP_SESSION_ID"}
      child = subprocess.Popen(["sleep", "60"], env=env)
      (repo / "unmarked.pid").write_text(str(child.pid))
  (repo / "argv").write_text("\\n".join(args))
  if (repo / "sleep").exists():
      time.sleep(float((repo / "sleep").read_text()))
  print("chg-replay-selection: building", file=sys.stderr, flush=True)
  print((repo / "replay.out").read_text())
  if (repo / "extra").exists():
      print('{"corpus": []}')
  """

  # What the PULL REQUEST's copy of the script says: never what runs.
  @head_script """
  print('{"corpus": []}')
  """

  @replay %{
    "corpus" =>
      for(
        n <- 1..5,
        do: %{
          "sha" => String.duplicate("#{n}", 40),
          "base_count" => 3,
          "head_count" => 4,
          "dropped" => []
        }
      )
  }

  setup do
    root = tmp_dir!("selection-replay")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(origin)
    git!(origin, ["init", "-q", "--bare", "-b", "master"])

    seed = git_repo!(Path.join(root, "seed"))
    write!(seed, "bin/chg-replay-selection.py", @base_script)
    write!(seed, "cli/src/cover.rs", "fn select() {}\n")
    write!(seed, "docs/notes.md", "notes\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-q", "-m", "base"])
    git!(seed, ["remote", "add", "origin", origin])
    git!(seed, ["push", "-q", "origin", "master"])
    base = git!(seed, ["rev-parse", "HEAD"])

    product = Path.join(root, "product")
    File.mkdir_p!(product)
    File.write!(Path.join(product, "replay.out"), Jason.encode!(@replay))

    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    {:ok, template} = Templates.fetch({"verify", 1})

    {:ok,
     root: root,
     seed: seed,
     origin: origin,
     base: base,
     product: product,
     state: state,
     template: template}
  end

  defp write!(dir, file, text) do
    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  # The pull request: `files` changed on a branch, pushed as refs/pull/7/head only, then the
  # runner's checkout cloned without it.
  defp pull_request!(ctx, files) do
    git!(ctx.seed, ["checkout", "-q", "-B", "loop/story-1", "master"])
    Enum.each(files, fn {file, text} -> write!(ctx.seed, file, text) end)
    git!(ctx.seed, ["add", "."])
    git!(ctx.seed, ["commit", "-q", "-m", "change"])
    head = git!(ctx.seed, ["rev-parse", "HEAD"])
    git!(ctx.seed, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
    git!(ctx.root, ["clone", "-q", "--no-local", ctx.origin, "repo"])
    head
  end

  # The fake session holds its turn until the replay has started (its script has written argv),
  # so a session ending is never mistaken for a replay that had not begun.
  defp session_env(ctx, final_message, wait?) do
    probe =
      if wait?,
        do: %{
          "FAKE_PROBE_CMD" =>
            "i=0; while [ ! -e #{ctx.product}/argv ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done"
        },
        else: %{}

    Map.merge(base_session_env(ctx, final_message), probe)
  end

  defp base_session_env(ctx, final_message) do
    path =
      [fake_bin_dir() | Enum.map(~w(git bash perl sed awk), &tool_dir/1)]
      |> Kernel.++(["/usr/local/bin", "/usr/bin", "/bin"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(":")

    %{
      "PATH" => path,
      "FAKE_STATE_DIR" => ctx.state,
      "FAKE_CLAUDE_MODE" => "stream",
      "FAKE_RESULT_LINE" =>
        Jason.encode!(%{"type" => "result", "subtype" => "success", "result" => final_message})
    }
  end

  defp tool_dir(name) do
    case System.find_executable(name) do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  defp config_for(ctx, verdict, wait? \\ true) do
    config!(ctx.root, %{
      "park_after_s" => 600,
      "repos" => %{"fixture" => Path.join(ctx.root, "repo"), "product" => ctx.product},
      "session_env" => %{"fixture" => session_env(ctx, block(verdict), wait?)},
      "selection_replay" => %{"fixture" => %{"product" => "product", "paths" => ["cli/src/**"]}}
    })
  end

  defp block(verdict), do: "Judged.\n\n```json\n#{Jason.encode!(verdict)}\n```"

  defp run(ctx, config, head, verify_extra \\ %{}) do
    dispatch = %{
      "dispatch_id" => Session.uuid4(),
      "story_id" => @story_id,
      "kind" => "verify",
      "repo" => "mkreyman/fixture",
      "branch" => "loop/story-1",
      "base_branch" => "master",
      "claim_epoch" => 4,
      "story" => %{"id" => @story_id, "title" => "Widen", "acceptance_criteria" => ["widens"]},
      "verify" => Map.merge(%{"pr_number" => 7, "head_sha" => head}, verify_extra)
    }

    {:ok, subject} = TriageRun.subject(ctx.template, dispatch)

    TriageRun.execute(config, subject, "mkreyman/fixture",
      template: ctx.template,
      binding: Map.take(dispatch, ["dispatch_id", "claim_epoch"]),
      wall_clock_s: 60,
      max_turns: 5
    )
  end

  defp events(run_dir, name) do
    run_dir
    |> Path.join("trace.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["type"] == name))
  end

  @pass %{"verdict" => "pass", "findings" => []}

  describe "a pass on a change to selection code" do
    test "carries the replay the BASE's script printed, run on the merge base and the head",
         ctx do
      head =
        pull_request!(ctx, [
          {"cli/src/cover.rs", "fn select() { widen() }\n"},
          {"bin/chg-replay-selection.py", @head_script}
        ])

      result = run(ctx, config_for(ctx, @pass), head)

      assert {:agent_result, {"verify", 1}, sent} = result.outcome

      assert sent == %{
               "verdict" => "pass",
               "findings" => [],
               "head_sha" => head,
               "selection_replay" => @replay
             }

      argv = ctx.product |> Path.join("argv") |> File.read!() |> String.split("\n")
      assert ["--base", ctx.base] == argv |> Enum.drop_while(&(&1 != "--base")) |> Enum.take(2)
      assert ["--head", head] == argv |> Enum.drop_while(&(&1 != "--head")) |> Enum.take(2)
      assert ["--repo", ctx.product] == argv |> Enum.drop_while(&(&1 != "--repo")) |> Enum.take(2)
      assert ["--corpus", "5"] == argv |> Enum.drop_while(&(&1 != "--corpus")) |> Enum.take(2)

      assert [%{"data" => %{"matched" => ["cli/src/cover.rs"]}}] =
               events(result.run_dir, "selection_replay.started")

      assert {:ok, %{"selection_replay" => %{"marker_id" => marker}}} =
               RunState.read(result.run_dir)

      assert ProcessGroup.marked(ProcessGroup.marker(marker)) == []
    end

    test "a story from a selection_miss replays at the finding's commit with its failures, and " <>
           "the miss reaches the pass",
         ctx do
      miss_sha = String.duplicate("a", 40)
      failures = ["test/a_test.exs:12", "-dashed test name"]
      replay = Map.put(@replay, "miss", %{"sha" => miss_sha, "covered" => failures})
      File.write!(Path.join(ctx.product, "replay.out"), Jason.encode!(replay))
      head = pull_request!(ctx, [{"cli/src/cover.rs", "fn select() { widen() }\n"}])

      result =
        run(ctx, config_for(ctx, @pass), head, %{
          "loop_finding" => %{"sha" => miss_sha, "failures" => failures}
        })

      assert {:agent_result, {"verify", 1}, sent} = result.outcome
      assert sent["selection_replay"] == replay

      argv = ctx.product |> Path.join("argv") |> File.read!() |> String.split("\n")
      assert ["--miss", miss_sha] == argv |> Enum.drop_while(&(&1 != "--miss")) |> Enum.take(2)

      assert Enum.filter(argv, &String.starts_with?(&1, "--failure")) ==
               ["--failure=test/a_test.exs:12", "--failure=-dashed test name"]

      assert [%{"data" => %{"miss" => ^miss_sha}}] =
               events(result.run_dir, "selection_replay.started")
    end

    test "a story from no finding passes no miss", ctx do
      head = pull_request!(ctx, [{"cli/src/cover.rs", "fn select() { widen() }\n"}])
      result = run(ctx, config_for(ctx, @pass), head)

      argv = ctx.product |> Path.join("argv") |> File.read!() |> String.split("\n")
      refute Enum.any?(argv, &String.starts_with?(&1, "--miss"))
      refute Enum.any?(argv, &String.starts_with?(&1, "--failure"))
      assert [%{"data" => %{"miss" => nil}}] = events(result.run_dir, "selection_replay.started")
    end

    test "a replay that prints something outside the schema leaves the pass without it", ctx do
      File.write!(Path.join(ctx.product, "replay.out"), ~s({"corpus": [{"sha": "nope"}]}))
      head = pull_request!(ctx, [{"cli/src/cover.rs", "fn select() { widen() }\n"}])
      result = run(ctx, config_for(ctx, @pass), head)

      assert {:agent_result, {"verify", 1}, sent} = result.outcome
      refute Map.has_key?(sent, "selection_replay")
      assert sent["verdict"] == "pass"

      assert [%{"data" => %{"reason" => reason}}] =
               events(result.run_dir, "selection_replay.failed")

      assert reason =~ "schema"
    end

    test "a second line on stdout leaves the pass without it, whichever line came last", ctx do
      File.write!(Path.join(ctx.product, "extra"), "")
      head = pull_request!(ctx, [{"cli/src/cover.rs", "fn select() { widen() }\n"}])
      result = run(ctx, config_for(ctx, @pass), head)

      assert {:agent_result, {"verify", 1}, sent} = result.outcome
      refute Map.has_key?(sent, "selection_replay")

      assert [%{"data" => %{"reason" => reason}}] =
               events(result.run_dir, "selection_replay.failed")

      assert reason =~ "2 lines on stdout"
    end
  end

  test "a reject never waits for the replay, and ends it", ctx do
    File.write!(Path.join(ctx.product, "sleep"), "40")
    File.write!(Path.join(ctx.product, "unmarked"), "")
    head = pull_request!(ctx, [{"cli/src/cover.rs", "fn select() { narrow() }\n"}])
    verdict = %{"verdict" => "reject", "findings" => ["narrows selection"]}
    started = System.monotonic_time(:millisecond)
    result = run(ctx, config_for(ctx, verdict), head)

    assert {:agent_result, {"verify", 1}, sent} = result.outcome
    refute Map.has_key?(sent, "selection_replay")
    assert System.monotonic_time(:millisecond) - started < 30_000

    {:ok, %{"selection_replay" => %{"marker_id" => marker}}} = RunState.read(result.run_dir)
    assert ProcessGroup.marked(ProcessGroup.marker(marker)) == []

    # The child the marker cannot see went with the group.
    unmarked = File.read!(Path.join(ctx.product, "unmarked.pid"))
    assert wait_until(fn -> not pid_alive?(unmarked) end) == :ok
  end

  defp pid_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  test "a change that touches no selection path runs no replay", ctx do
    head = pull_request!(ctx, [{"docs/notes.md", "more notes\n"}])
    result = run(ctx, config_for(ctx, @pass, false), head)

    assert {:agent_result, {"verify", 1}, sent} = result.outcome
    refute Map.has_key?(sent, "selection_replay")
    refute File.exists?(Path.join(ctx.product, "argv"))

    assert [%{"data" => %{"reason" => "the change touches no selection path"}}] =
             events(result.run_dir, "selection_replay.skipped")
  end

  test "a renamed-away selection file counts as touching it", ctx do
    git!(ctx.seed, ["checkout", "-q", "-B", "loop/story-1", "master"])
    git!(ctx.seed, ["mv", "cli/src/cover.rs", "docs/cover.rs"])
    git!(ctx.seed, ["commit", "-q", "-m", "move"])
    head = git!(ctx.seed, ["rev-parse", "HEAD"])
    git!(ctx.seed, ["push", "-q", "-f", "origin", "HEAD:refs/pull/7/head"])
    git!(ctx.root, ["clone", "-q", "--no-local", ctx.origin, "repo"])

    result = run(ctx, config_for(ctx, @pass), head)
    assert {:agent_result, {"verify", 1}, %{"selection_replay" => @replay}} = result.outcome
  end

  test "the reaper ends an orphaned run's replay by its own marker" do
    marker_id = Session.uuid4()

    _port =
      Port.open({:spawn_executable, System.find_executable("sleep")},
        args: ["30"],
        env: [{~c"LOOP_SESSION_ID", to_charlist(marker_id)}]
      )

    marker = ProcessGroup.marker(marker_id)
    assert wait_until(fn -> ProcessGroup.marked(marker) != [] end) == :ok

    state = %{"status" => "running", "selection_replay" => %{"marker_id" => marker_id}}
    assert {:gone, _} = LoopctlRunner.Reaper.end_session_outcome(state, 2_000)
    assert ProcessGroup.marked(marker) == []
  end

  test "the reaper ends an orphaned replay's recorded group, which no marker names" do
    parent = self()

    task =
      Task.async(fn ->
        ProcessGroup.run_group("sleep", ["30"], 60_000, [],
          on_start: fn pgid -> send(parent, {:pgid, pgid}) end
        )
      end)

    assert_receive {:pgid, pgid}, 5_000
    group_file = Path.join(tmp_dir!("replay-group"), "selection-replay.group")
    File.write!(group_file, "#{pgid} #{LoopctlRunner.Owner.start_id(pgid)}\n")

    state = %{
      "status" => "running",
      "selection_replay" => %{"marker_id" => Session.uuid4(), "group_file" => group_file}
    }

    assert {:gone, _} = LoopctlRunner.Reaper.end_session_outcome(state, 2_000)
    refute ProcessGroup.alive?(pgid)
    assert {:ok, _out, _status} = Task.await(task)
  end

  describe "a verify dispatch's loop_finding" do
    defp verify_dispatch(loop_finding) do
      %{
        "kind" => "verify",
        "story_id" => @story_id,
        "branch" => "loop/story-1",
        "base_branch" => "master",
        "story" => %{"id" => @story_id, "title" => "Widen", "acceptance_criteria" => ["widens"]},
        "verify" => %{
          "pr_number" => 7,
          "head_sha" => String.duplicate("b", 40),
          "loop_finding" => loop_finding
        }
      }
    end

    test "a well-formed one is kept on the subject", ctx do
      finding = %{"sha" => String.duplicate("a", 40), "failures" => ["t:1"]}
      assert {:ok, subject} = TriageRun.subject(ctx.template, verify_dispatch(finding))
      assert subject["verify"]["loop_finding"] == finding
    end

    for {name, finding} <- [
          {"a short sha", %{"sha" => "abc", "failures" => []}},
          {"an uppercase sha", %{"sha" => String.duplicate("A", 40), "failures" => []}},
          {"an empty failure name", %{"sha" => String.duplicate("a", 40), "failures" => [""]}},
          {"a 201-character name",
           %{"sha" => String.duplicate("a", 40), "failures" => [String.duplicate("x", 201)]}},
          {"51 failures",
           %{"sha" => String.duplicate("a", 40), "failures" => List.duplicate("t", 51)}},
          {"no failures key", %{"sha" => String.duplicate("a", 40)}}
        ] do
      test "#{name} refuses the dispatch rather than reaching the replay's command line", ctx do
        assert {:error, detail} =
                 TriageRun.subject(ctx.template, verify_dispatch(unquote(Macro.escape(finding))))

        assert detail =~ "loop_finding is malformed"
      end
    end
  end

  describe "from_config/2" do
    @repos %{"chg" => "/c", "hcb" => "/h"}

    test "absent is no entry" do
      assert SelectionReplay.from_config(%{}, @repos) == {:ok, %{}}
    end

    test "an entry, with the default corpus" do
      map = %{
        "selection_replay" => %{"chg" => %{"product" => "hcb", "paths" => ["cli/src/cover.rs"]}}
      }

      assert SelectionReplay.from_config(map, @repos) ==
               {:ok, %{"chg" => %{product: "hcb", paths: ["cli/src/cover.rs"], corpus: 5}}}
    end

    for {name, entry, reason} <- [
          {"a repo not in repos", {"nope", %{"product" => "hcb", "paths" => ["a"]}},
           "not in repos"},
          {"a product not in repos", {"chg", %{"product" => "x", "paths" => ["a"]}}, "product"},
          {"no paths", {"chg", %{"product" => "hcb", "paths" => []}}, "paths"},
          {"an absolute path", {"chg", %{"product" => "hcb", "paths" => ["/a"]}}, "paths"},
          {"a corpus loopctl would refuse",
           {"chg", %{"product" => "hcb", "paths" => ["a"], "corpus" => 4}}, "fewer than 5"},
          {"a corpus over the script's cap",
           {"chg", %{"product" => "hcb", "paths" => ["a"], "corpus" => 31}}, "corpus"},
          {"an unknown key", {"chg", %{"product" => "hcb", "paths" => ["a"], "x" => 1}},
           "unknown"}
        ] do
      test "refuses #{name}" do
        {repo, raw} = unquote(Macro.escape(entry))

        assert {:error, message} =
                 SelectionReplay.from_config(%{"selection_replay" => %{repo => raw}}, @repos)

        assert message =~ unquote(reason)
      end
    end

    test "a config carrying a bad entry does not load", ctx do
      map =
        config_map(ctx.root, %{
          "selection_replay" => %{"fixture" => %{"product" => "nope", "paths" => ["a"]}}
        })

      assert {:error, _} = LoopctlRunner.Config.from_map(map)
    end
  end

  describe "glob_match?/2" do
    for {pattern, path, expected} <- [
          {"cli/src/cover.rs", "cli/src/cover.rs", true},
          {"cli/src/cover.rs", "cli/src/cover.rsx", false},
          {"adapters/*/lib/**", "adapters/elixir/lib/chg_adapter/select.ex", true},
          {"adapters/*/lib/**", "adapters/elixir/test/select_test.exs", false},
          {"adapters/*/lib/**", "adapters/a/b/lib/x.ex", false},
          {"a/**/b.ex", "a/b.ex", true},
          {"a/**/b.ex", "a/x/y/b.ex", true},
          {"*.rs", "src/x.rs", false},
          {"cli/src/?over.rs", "cli/src/cover.rs", true},
          {"a.b", "aXb", false}
        ] do
      test "#{pattern} against #{path} is #{expected}" do
        assert SelectionReplay.glob_match?(unquote(pattern), unquote(path)) == unquote(expected)
      end
    end
  end

  describe "parse/1" do
    test "reads its one line" do
      assert SelectionReplay.parse("#{Jason.encode!(@replay)}\n") == {:ok, @replay}
    end

    test "refuses more than one line, so no later writer chooses the measurement" do
      assert {:error, message} = SelectionReplay.parse("building\n#{Jason.encode!(@replay)}\n")
      assert message =~ "2 lines"

      assert {:error, _} =
               SelectionReplay.parse("#{Jason.encode!(@replay)}\n#{Jason.encode!(@replay)}\n")
    end

    test "refuses output with no object" do
      assert {:error, "the replay printed nothing"} = SelectionReplay.parse("\n\n")
      assert {:error, message} = SelectionReplay.parse("chg-replay-selection: build failed")
      assert message =~ "not a JSON object"
    end

    test "refuses a corpus entry the schema refuses" do
      too_many_dropped = %{
        "corpus" => [
          %{
            "sha" => String.duplicate("a", 40),
            "base_count" => 1,
            "head_count" => 0,
            "dropped" => ["a", "b", "c", "d"]
          }
        ]
      }

      assert {:error, message} = SelectionReplay.parse(Jason.encode!(too_many_dropped))
      assert message =~ "schema"
    end
  end
end
