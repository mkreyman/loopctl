defmodule LoopctlRunner.SpecTuneRunTest do
  @moduledoc """
  US-48.13, a `spec_tuner@1` run end to end on the detached-tree path: the dispatch's repo checked
  out detached at its base, the tuning session's final block read off the fake CLI, the CRITIC
  (the eval harness, on the fake CLI too) scoring it, and the result recorded before anything is
  sent — keyed by the dispatch, never a story.

  Async: the tuning session reaches the fake through the repo's `session_env` and the critic's
  sessions through `:critic`'s `cli_dir` — data on this test's config and options, never this
  BEAM's environment — and every path is the test's own `tmp_dir`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  alias LoopctlRunner.{Contract, PendingVerdicts, RunState, Templates, TriageRun}

  @moduletag timeout: 180_000

  @eval_dir Path.expand("../../eval", __DIR__)
  @pinned "6275d38f062136ea998174995850b1bf3be1ba86"
  @dispatch_id "0f1e2d3c-4b5a-4697-8877-665544332211"
  @trace_id "5a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @rule "0. Never name the system that handles the ticket."
  @leaky ~s(```json\n{"body": "Thanks. loopctl will look at it."}\n```)
  @clean ~s(```json\n{"body": "Thanks for the report. A person will look into it."}\n```)

  setup do
    root = tmp_dir!("spec-tune-run")
    checkout = git_repo!(Path.join(root, "repo"))
    state = Path.join(root, "fake")
    File.mkdir_p!(state)
    {:ok, template} = Templates.fetch({"spec_tuner", 1})
    eval_dir = own_eval_dir!(root)

    {:ok,
     root: root,
     checkout: checkout,
     base: git!(checkout, ["rev-parse", "HEAD"]),
     state: state,
     template: template,
     eval_dir: eval_dir}
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp own_eval_dir!(root) do
    dir = Path.join(root, "eval")
    File.mkdir_p!(Path.join(dir, "fixtures"))
    File.mkdir_p!(Path.join(dir, "reply_draft@1"))
    File.mkdir_p!(Path.join([dir, "offline", "reply_draft@1"]))

    File.cp!(
      Path.join(@eval_dir, "fixtures/tiny_app.json"),
      Path.join(dir, "fixtures/tiny_app.json")
    )

    raw = read_json!(Path.join([@eval_dir, "reply_draft@1", "r01_acknowledge_defect.json"]))

    File.write!(
      Path.join([dir, "reply_draft@1", "r01_acknowledge_defect.json"]),
      Jason.encode!(raw)
    )

    switching =
      Jason.encode!(%{
        "final_message" => @leaky,
        "when_prompt_contains" => %{"text" => @rule, "final_message" => @clean}
      })

    for name <- ["r01_acknowledge_defect", "n01_names_no_system"] do
      File.write!(Path.join([dir, "offline", "reply_draft@1", name <> ".json"]), switching)
    end

    dir
  end

  defp tool_dir(name) do
    case System.find_executable(name) do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  # The tuning session's fake, as config data: its final message is the proposal, from a file of
  # the test's own because it is longer than a session_env value may be.
  defp config_for(ctx, final_message) do
    line_file = Path.join(ctx.root, "result-line-#{System.unique_integer([:positive])}.json")

    File.write!(
      line_file,
      Jason.encode!(%{"type" => "result", "subtype" => "success", "result" => final_message})
    )

    path =
      [fake_bin_dir() | Enum.map(~w(git bash perl sed awk), &tool_dir/1)]
      |> Kernel.++(["/usr/local/bin", "/usr/bin", "/bin"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(":")

    config!(ctx.root, %{
      "park_after_s" => 600,
      # A tuning dispatch's wall clock holds its critic's sessions too (`dispatch/0`).
      "max_wall_clock_s" => 3600,
      "session_env" => %{
        "fixture" => %{
          "PATH" => path,
          "FAKE_STATE_DIR" => ctx.state,
          "FAKE_CLAUDE_MODE" => "stream",
          "FAKE_RESULT_LINE_FILE" => line_file,
          "FAKE_PROBE_CMD" => "git rev-parse --abbrev-ref HEAD; git rev-parse HEAD"
        }
      }
    })
  end

  defp dispatch do
    %{
      "dispatch_id" => @dispatch_id,
      "kind" => "spec_tune",
      "repo" => "mkreyman/fixture",
      "base_branch" => "master",
      "branch" => "master",
      "claim_epoch" => 0,
      # The run's whole bound when no deadline_at is sent: the tuning session AND the critic's
      # four case sessions (two passes of two 600 s reply_draft cases) must fit inside it.
      "wall_clock_seconds" => 3600,
      "max_turns" => 5,
      "spec_tune" => %{
        "target" => %{"id" => "reply_draft", "version" => 1},
        "template" => %{"id" => "reply_draft", "version" => 1},
        "eval_set" => "reply_draft@1",
        "window" => %{"since" => nil, "until" => "2026-11-07T06:00:00Z"},
        "outcome_rows" => 24,
        "traces" => [
          %{
            "trace_id" => @trace_id,
            "failures" => ["human_override"],
            "agent_decision" => %{"outcome" => "agent_result"},
            "human_decision" => %{"route" => "reply", "outcomes" => ["agent_result"]},
            "untrusted" =>
              "<<<UNTRUSTED story_text a1>>>\n| loopctl was named\n<<<END UNTRUSTED story_text a1>>>"
          }
        ]
      }
    }
  end

  defp proposal do
    input =
      read_json!(Path.join([@eval_dir, "reply_draft@1", "r01_acknowledge_defect.json"]))["input"]
      |> Map.put("dispatch_id", "e7a12090-0000-4000-8000-000000000001")

    %{
      "new_cases" => [
        %{
          "name" => "n01_names_no_system",
          "source_trace_id" => @trace_id,
          "description" => "The draft must not name the system behind the ticket.",
          "input" => input,
          "fixture" => %{"repo" => "fixtures/tiny_app.json", "commit" => @pinned},
          "expectations" => %{
            "schema_valid" => true,
            "outcomes_allowed" => ["agent_result"],
            "escalation_codes" => [],
            "lens_agreement" => nil,
            "forbidden" => ["(?i)\\bloopctl\\b"],
            "screens" => [],
            "rubric" => nil
          }
        }
      ],
      "proposed_template" => %{
        "id" => "reply_draft",
        "from_version" => 1,
        "to_version" => 2,
        "diff" => "@@ -9,1 +9,2 @@\n What to do:\n+#{@rule}"
      }
    }
  end

  defp block(stated), do: "I read the traces.\n\n```json\n#{Jason.encode!(stated)}\n```"

  defp run(ctx, config, dispatch \\ dispatch(), opts \\ []) do
    {:ok, subject} = TriageRun.subject(ctx.template, dispatch)

    TriageRun.execute(
      config,
      subject,
      "mkreyman/fixture",
      Keyword.merge(
        [
          template: ctx.template,
          binding: LoopctlRunner.DispatchRun.binding(dispatch),
          wall_clock_s: dispatch["wall_clock_seconds"],
          max_turns: dispatch["max_turns"],
          critic: [
            eval_dir: ctx.eval_dir,
            cli_dir: fake_bin_dir(),
            machine: "testbox (offline: fake CLI)"
          ]
        ],
        opts
      )
    )
  end

  defp argv(ctx), do: ctx.state |> Path.join("argv") |> File.read!() |> String.split("\n")

  defp probe(ctx),
    do: ctx.state |> Path.join("probe") |> File.read!() |> String.split("\n", trim: true)

  test "a proposal is scored by the harness, recorded as spec_tuner@1, and keyed by the dispatch",
       ctx do
    result = run(ctx, config_for(ctx, block(proposal())))

    assert {:agent_result, {"spec_tuner", 1}, sent} = result.outcome

    assert sent["scores"] == %{
             "current" => %{"passed" => 0, "total" => 2},
             "proposed" => %{"passed" => 2, "total" => 2},
             "per_case" => [
               %{
                 "case" => "r01_acknowledge_defect",
                 "existing" => true,
                 "current" => false,
                 "proposed" => true
               },
               %{
                 "case" => "n01_names_no_system",
                 "existing" => false,
                 "current" => false,
                 "proposed" => true
               }
             ]
           }

    refute Map.has_key?(hd(sent["new_cases"]), "input")

    # Keyed by the dispatch: no story anywhere in its directory name or its state.
    assert Path.basename(result.run_dir) =~ ~r/\Aspec_tune-#{@dispatch_id}-/
    {:ok, state} = RunState.read(result.run_dir)
    assert state["record_id"] == @dispatch_id
    assert state["kind"] == "spec_tune"
    refute Map.has_key?(state, "story_id")

    # Recorded as the message before anyone is told: what a restart resends, byte for byte.
    assert {:ok, payload} = PendingVerdicts.read(result.run_dir)

    assert payload == %{
             "dispatch_id" => @dispatch_id,
             "claim_epoch" => 0,
             "spec" => %{"id" => "spec_tuner", "version" => 1},
             "result" => sent
           }

    assert Contract.validate("RunnerAgentResultMessage", payload) == :ok
    assert {:ok, ^payload} = TriageRun.message(dispatch(), result.outcome)

    # The session ran in a DETACHED tree of the repo at its base, never a branch of its own.
    assert probe(ctx) == ["HEAD", ctx.base]
    assert git!(ctx.checkout, ["rev-parse", "--abbrev-ref", "HEAD"]) == "master"

    # The critic's results are the run's own; its scratch is gone.
    assert File.dir?(Path.join([result.run_dir, "critic-results", "current"]))
    refute File.exists?(Path.join([result.run_dir, "critic", "current"]))

    # Its sessions' runs outlive the scratch, where the reaper reads them: one per case per pass.
    nested = RunState.nested(Path.dirname(result.run_dir))
    assert length(nested) == 4
    assert Enum.all?(nested, &String.starts_with?(&1, RunState.nested_runs_dir(result.run_dir)))
  end

  test "the tuning session's argv carries no tool list and no settings or MCP override", ctx do
    _ = run(ctx, config_for(ctx, block(proposal())))
    args = argv(ctx)

    for flag <- ~w(--tools --allowedTools --allowed-tools --disallowedTools --disallowed-tools
                   --settings --mcp-config --strict-mcp-config) do
      refute flag in args, flag
    end

    assert "bypassPermissions" in args
    # The prompt is the last argument; the fake records one argument per line, so it is the tail.
    prompt = Enum.join(Enum.drop_while(args, &(&1 != "--")), "\n")
    assert prompt =~ "----- BEGIN CURRENT TEMPLATE reply_draft@1 -----"
    assert prompt =~ "----- CASE r01_acknowledge_defect -----"
    assert prompt =~ "----- TRACE #{@trace_id} -----"
    assert prompt =~ "use no loopctl tool of any kind"
  end

  test "a run read back from disk is never re-scored: no session, no result", ctx do
    result = run(ctx, config_for(ctx, block(proposal())))

    assert {:no_result, detail} = TriageRun.outcome_on_disk(result.run_dir, ctx.template)
    assert detail =~ "ended before its critic scored the proposal"
  end

  test "a malformed proposal sends nothing and records nothing", ctx do
    stated = Map.put(proposal(), "scores", %{"current" => %{"passed" => 9, "total" => 9}})

    capture_log(fn ->
      result = run(ctx, config_for(ctx, block(stated)))
      send(self(), {:result, result})
    end)

    assert_received {:result, result}
    assert {:no_result, detail} = result.outcome
    assert detail =~ "malformed"
    assert PendingVerdicts.read(result.run_dir) == :none
    refute File.exists?(Path.join(result.run_dir, "critic-results"))
  end

  # Control holds the spec_tune object to the contract's 48000 bytes, but the prompt also carries
  # the template text and every case, so the run bounds the whole argv itself.
  test "a tuning prompt over the cap runs no session and records nothing", ctx do
    huge = String.duplicate("| x\n", 32_000)

    dispatch =
      update_in(dispatch(), ["spec_tune", "traces"], fn [trace] ->
        [%{trace | "untrusted" => huge}]
      end)

    capture_log(fn ->
      result = run(ctx, config_for(ctx, block(proposal())), dispatch)
      send(self(), {:result, result})
    end)

    assert_received {:result, result}
    assert {:no_result, detail} = result.outcome
    assert detail =~ "over 120000"
    refute File.exists?(Path.join(ctx.state, "argv"))
    assert PendingVerdicts.read(result.run_dir) == :none
  end

  # The critic's sessions run inside the tuning dispatch's time. A deadline_at EARLIER than the
  # run's start + wall_clock_seconds wins: 300 s to it holds the tuning session but not a
  # reply_draft case's whole 600 s session, so the critic stops,
  # nothing is recorded, and nothing is sent: a proposal half-scored is not a result.
  test "a deadline that holds the tuning session but not its critic sends no result", ctx do
    deadline = DateTime.add(DateTime.utc_now(), 300, :second)

    log =
      capture_log(fn ->
        result = run(ctx, config_for(ctx, block(proposal())), dispatch(), deadline_at: deadline)
        send(self(), {:result, result})
      end)

    assert_received {:result, result}
    assert {:no_result, detail} = result.outcome
    assert detail =~ "the eval stops before case reply_draft@1/r01_acknowledge_defect"
    assert detail =~ "less than its 600s session"
    assert log =~ "the eval stops before case reply_draft@1/r01_acknowledge_defect"
    # The tuning session ran; the critic started no session at all.
    assert File.exists?(Path.join(ctx.state, "argv"))
    refute File.exists?(Path.join([result.run_dir, "critic-results", "current"]))
    assert PendingVerdicts.read(result.run_dir) == :none
  end

  # The shape loopctl actually sends (`Loopctl.Agents.Tuning.send_tuning`): wall_clock_seconds and
  # max_turns, and NO deadline_at. The run's own start + wall_clock_seconds is then the bound the
  # critic is held to, so a 300 s tuning dispatch cannot run a 600 s case session: loopctl's heal
  # frees the reservation once that clock is out, and a result sent after it is refused.
  test "with no deadline_at, the run's start + wall_clock_seconds bounds the critic", ctx do
    dispatch = Map.put(dispatch(), "wall_clock_seconds", 300)
    refute Map.has_key?(dispatch, "deadline_at")

    log =
      capture_log(fn ->
        result = run(ctx, config_for(ctx, block(proposal())), dispatch)
        send(self(), {:result, result})
      end)

    assert_received {:result, result}
    assert {:no_result, detail} = result.outcome
    assert detail =~ "the eval stops before case reply_draft@1/r01_acknowledge_defect"
    assert detail =~ "less than its 600s session"
    assert log =~ "the eval stops before case reply_draft@1/r01_acknowledge_defect"
    # The tuning session ran, inside the same bound; the critic started no session at all.
    assert File.exists?(Path.join(ctx.state, "argv"))
    refute File.exists?(Path.join([result.run_dir, "critic-results", "current"]))
    assert PendingVerdicts.read(result.run_dir) == :none

    # The tuning session's own stop was aimed by the derived bound, not its bare wall clock.
    {:ok, events} = LoopctlRunner.Trace.read(Path.join(result.run_dir, "trace.ndjson"))
    started = Enum.find(events, &(&1["type"] == "session.started"))
    assert {:ok, bound, _} = DateTime.from_iso8601(started["data"]["deadline_at"])
    assert DateTime.diff(bound, DateTime.utc_now(), :second) in 200..300
  end

  test "an eval set the runner does not hold ends the run before any session", ctx do
    File.rm_rf!(Path.join(ctx.eval_dir, "reply_draft@1"))

    capture_log(fn ->
      result = run(ctx, config_for(ctx, block(proposal())))
      send(self(), {:result, result})
    end)

    assert_received {:result, result}
    assert {:no_result, detail} = result.outcome
    assert detail =~ "eval set could not be prepared"
    refute File.exists?(Path.join(ctx.state, "argv"))
    assert PendingVerdicts.read(result.run_dir) == :none
  end
end
