defmodule LoopctlRunner.ControlSpecTuneTest do
  @moduledoc """
  US-48.13, Control's half of a `spec_tune` dispatch (contract 1.30.0): declared on join, held to
  the story-less shape in both directions, accepted on the detached-tree path keyed by its
  dispatch, run with its critic options, and its `spec_tuner@1` result sent as an `agent_result` —
  kept on disk first and resent after a restart, unchanged.

  The run itself is injected (`:triage_run`); `LoopctlRunner.SpecTuneRunTest` covers the run.
  """

  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    AgentResult,
    Contract,
    Control,
    ControlConfig,
    PendingVerdicts,
    RunState,
    Session,
    TestLoopctl
  }

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  @spec_ref %{"id" => "spec_tuner", "version" => 1}
  @trace_id "5a1d2c3b-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-spec-tune")
    token_file = Path.join(root, "token")
    File.write!(token_file, TestLoopctl.get(:token) <> "\n")
    File.chmod!(token_file, 0o600)

    control = %ControlConfig{
      url: "ws://127.0.0.1:#{port}/runner/socket/websocket",
      runner_id: TestLoopctl.get(:runner_id),
      machine: "testbox",
      token_file: token_file,
      repos: ["mkreyman/fixture"],
      max_sessions: 2,
      status_interval_s: 30,
      accepts_dispatches: true,
      min_free_disk_mb: 0
    }

    git_repo!(Path.join(root, "repo"))

    {:ok,
     config: %{config!(root) | control: control},
     root: root,
     run_supervisor: start_supervised!(Task.Supervisor)}
  end

  defp running_control(ctx, opts) do
    test = self()

    opts =
      Keyword.merge(
        [
          config: ctx.config,
          on_fatal: &send(test, {:fatal, &1}),
          run_supervisor: ctx.run_supervisor,
          trace_poll_ms: 200
        ],
        opts
      )

    {:ok, pid} = GenServer.start(Control, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
    {pid, "runner:" <> TestLoopctl.get(:runner_id)}
  end

  # A spec_tune dispatch as loopctl's send_tuning sends one: no story_id, claim_epoch 0, the
  # repo's base as its branch, the triage budgets, and the spec_tune object.
  defp tune_dispatch(overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "kind" => "spec_tune",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "master",
        "claim_epoch" => 0,
        "wall_clock_seconds" => 30,
        "max_turns" => 7,
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
                "<<<UNTRUSTED story_text a1>>>\n| x\n<<<END UNTRUSTED story_text a1>>>"
            }
          ]
        }
      },
      overrides
    )
  end

  defp result do
    %{
      "new_cases" => [
        %{
          "name" => "n01_names_no_system",
          "source_trace_id" => @trace_id,
          "description" => "The draft must not name the system behind the ticket.",
          "fixture" => %{
            "repo" => "fixtures/tiny_app.json",
            "commit" => "6275d38f062136ea998174995850b1bf3be1ba86"
          },
          "expectations" => %{
            "schema_valid" => true,
            "outcomes_allowed" => ["agent_result"],
            "escalation_codes" => [],
            "lens_agreement" => nil,
            "forbidden" => [],
            "screens" => [],
            "rubric" => nil
          }
        }
      ],
      "proposed_template" => %{
        "id" => "reply_draft",
        "from_version" => 1,
        "to_version" => 2,
        "diff" => "@@ -1,1 +1,2 @@\n x\n+y"
      },
      "scores" => %{
        "current" => %{"passed" => 0, "total" => 2},
        "proposed" => %{"passed" => 2, "total" => 2},
        "per_case" => [
          %{"case" => "r01", "existing" => true, "current" => false, "proposed" => true},
          %{
            "case" => "n01_names_no_system",
            "existing" => false,
            "current" => false,
            "proposed" => true
          }
        ]
      }
    }
  end

  defp fake_run(outcome) do
    test = self()

    fn config, subject, repo, opts ->
      run_id = Session.uuid4()
      run_dir = Path.join(config.runs_dir, "spec_tune-#{run_id}")
      File.mkdir_p!(run_dir)

      RunState.update(run_dir, %{"run_id" => run_id, "kind" => "spec_tune", "status" => "running"})

      Keyword.fetch!(opts, :on_start).(%{run_id: run_id, run_dir: run_dir})
      send(test, {:ran, subject, repo, opts})

      RunState.update(run_dir, %{"status" => "agent_result", "finished_at" => "now"})
      %{run_id: run_id, run_dir: run_dir, session: nil, outcome: outcome}
    end
  end

  defp next_result(timeout \\ 10_000) do
    receive do
      {:test_loopctl, {:agent_result, payload}} -> payload
    after
      timeout -> flunk("no agent_result within #{timeout}ms")
    end
  end

  defp reply!(topic, dispatch) do
    TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
    assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
    assert reply["dispatch_id"] == dispatch["dispatch_id"]
    reply
  end

  test "spec_tune is declared on join, with spec_tuner@1 among the specs", ctx do
    {_pid, _topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))
    runner_id = TestLoopctl.get(:runner_id)
    assert_received {:test_loopctl, {:join, ^runner_id, join}}
    assert "spec_tune" in join["kinds"]
    assert %{"id" => "spec_tuner", "version" => 1} in join["specs"]
    assert join["contract_version"] == "1.30.0"
  end

  test "a spec_tune is accepted with no story, run keyed by its dispatch, and answered spec_tuner@1",
       ctx do
    TestLoopctl.put(:agent_result_replies, [:ok])
    critic = [eval_dir: Path.join(ctx.root, "eval")]

    {pid, topic} =
      running_control(ctx,
        triage_run: fake_run({:agent_result, {"spec_tuner", 1}, result()}),
        critic: critic
      )

    dispatch = tune_dispatch()
    assert Contract.validate("RunnerDispatch", dispatch) == :ok
    assert reply!(topic, dispatch)["decision"] == "accepted"

    assert_receive {:ran, subject, "mkreyman/fixture", opts}, 5_000

    assert subject == %{
             "dispatch_id" => dispatch["dispatch_id"],
             "spec_tune" => dispatch["spec_tune"]
           }

    assert %{id: "spec_tuner", version: 1, kind: "spec_tune"} = opts[:template]
    assert opts[:binding] == %{"dispatch_id" => dispatch["dispatch_id"], "claim_epoch" => 0}
    assert opts[:critic] == critic
    assert opts[:wall_clock_s] == 30
    assert opts[:max_turns] == 7

    payload = next_result()

    assert payload == %{
             "dispatch_id" => dispatch["dispatch_id"],
             "claim_epoch" => 0,
             "spec" => @spec_ref,
             "result" => result()
           }

    assert Contract.validate("RunnerAgentResultMessage", payload) == :ok
    :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)
    assert PendingVerdicts.all(ctx.config.runs_dir) == []
  end

  test "a run with no result sends nothing: the dispatch lapses", ctx do
    {pid, topic} =
      running_control(ctx, triage_run: fake_run({:no_result, "the diff does not apply"}))

    capture_log(fn ->
      assert reply!(topic, tune_dispatch())["decision"] == "accepted"
      assert_receive {:ran, _, _, _}, 5_000
      :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 5_000)
    end)

    refute_receive {:test_loopctl, {:agent_result, _}}, 300
    refute_receive {:test_loopctl, {:triage_verdict, _}}, 100
  end

  describe "the story-less shape, in both directions" do
    for {name, overrides, detail} <- [
          {"a spec_tune carrying a story_id",
           %{"story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"},
           "a spec_tune dispatch names no story: story_id is not allowed"},
          {"a spec_tune with a claim_epoch", %{"claim_epoch" => 2},
           "a spec_tune dispatch claims nothing: claim_epoch must be 0"},
          {"a spec_tune with no spec_tune object", :drop_spec_tune,
           "a spec_tune dispatch must carry the spec_tune object"}
        ] do
      test "#{name} is refused other, and nothing runs", ctx do
        {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

        dispatch =
          case unquote(Macro.escape(overrides)) do
            :drop_spec_tune -> Map.delete(tune_dispatch(), "spec_tune")
            overrides -> tune_dispatch(overrides)
          end

        capture_log(fn ->
          reply = reply!(topic, dispatch)
          send(self(), {:reply, reply})
        end)

        assert_received {:reply,
                         %{"decision" => "refused", "reason" => "other", "detail" => detail}}

        assert detail == "invalid dispatch: " <> unquote(detail)
        refute_receive {:ran, _, _, _}, 300
      end
    end

    for kind <- ["implement", "triage", "reply_draft", "verify"] do
      test "a #{kind} with no story_id is refused other, and nothing runs", ctx do
        {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

        dispatch =
          tune_dispatch(%{"kind" => unquote(kind), "claim_epoch" => 3})
          |> Map.delete("spec_tune")

        capture_log(fn ->
          reply = reply!(topic, dispatch)
          send(self(), {:reply, reply})
        end)

        assert_received {:reply,
                         %{"decision" => "refused", "reason" => "other", "detail" => detail}}

        assert detail =~ "a #{unquote(kind)} dispatch must carry story_id"
        refute_receive {:ran, _, _, _}, 300
      end
    end

    test "a triage carrying a spec_tune object is refused other", ctx do
      {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

      dispatch =
        tune_dispatch(%{
          "kind" => "triage",
          "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
          "claim_epoch" => 3
        })

      capture_log(fn ->
        reply = reply!(topic, dispatch)
        send(self(), {:reply, reply})
      end)

      assert_received {:reply,
                       %{"decision" => "refused", "reason" => "other", "detail" => detail}}

      assert detail =~ "spec_tune is only allowed when kind is spec_tune"
      refute_receive {:ran, _, _, _}, 300
    end

    test "a spec_tune naming a template the runner does not hold is refused other", ctx do
      {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))
      dispatch = tune_dispatch()
      tune = %{dispatch["spec_tune"] | "template" => %{"id" => "reply_draft", "version" => 9}}

      capture_log(fn ->
        reply =
          reply!(topic, %{dispatch | "spec_tune" => tune})

        send(self(), {:reply, reply})
      end)

      assert_received {:reply,
                       %{"decision" => "refused", "reason" => "other", "detail" => detail}}

      assert detail =~ "holds no template reply_draft@9"
      refute_receive {:ran, _, _, _}, 300
    end
  end

  test "a spec_tuner@1 result recorded on disk is resent by the next Control, unchanged", ctx do
    TestLoopctl.put(:agent_result_replies, [:ok])
    dispatch = tune_dispatch()

    {:ok, recorded} =
      AgentResult.message(
        Map.take(dispatch, ["dispatch_id", "claim_epoch"]),
        {"spec_tuner", 1},
        result()
      )

    run_dir = Path.join(ctx.config.runs_dir, "spec_tune-#{dispatch["dispatch_id"]}-x")
    File.mkdir_p!(run_dir)
    :ok = PendingVerdicts.write(run_dir, recorded)

    {pid, _topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

    assert next_result() == recorded
    :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
    :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
  end
end
