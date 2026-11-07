defmodule LoopctlRunner.ControlVerifyTest do
  @moduledoc """
  US-48.18, Control's half of a verify dispatch: accepted on the detached-tree path, run over the
  story and the pull request it names, with the dispatch's own budgets, and its verdict sent as an
  `agent_result` naming `verify@1` — kept on disk first, resent after a restart, and given up on
  when loopctl refuses it permanently.

  The run itself is injected (`:triage_run`), so nothing here starts a session or changes this
  BEAM's environment; `LoopctlRunner.VerifyRunTest` covers the run.
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

  @spec_ref %{"id" => "verify", "version" => 1}
  @head String.duplicate("ab", 20)

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-verify")
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

  # A verify dispatch as VerifierPlacement sends one: the PR's own branch, the story, and the
  # `verify` object; no deadline_at.
  defp verify_dispatch(overrides \\ %{}) do
    story_id = Session.uuid4()

    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => story_id,
        "kind" => "verify",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "loop/story-1",
        "claim_epoch" => 2,
        "wall_clock_seconds" => 30,
        "max_turns" => 7,
        "story" => %{
          "id" => story_id,
          "title" => "Add a greeting",
          "acceptance_criteria" => ["hello is printed"]
        },
        "verify" => %{"pr_number" => 7, "head_sha" => @head}
      },
      overrides
    )
  end

  # The run, injected: it announces a directory, reports what it was given, and ends with
  # `outcome` — written through the run's own recording step (`TriageRun.message/2`) when the
  # outcome is a result, as the real run does.
  defp fake_run(outcome) do
    test = self()

    fn config, subject, repo, opts ->
      run_id = Session.uuid4()
      run_dir = Path.join(config.runs_dir, "verify-#{run_id}")
      File.mkdir_p!(run_dir)
      RunState.update(run_dir, %{"run_id" => run_id, "kind" => "verify", "status" => "running"})
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

  defp accept!(topic, dispatch) do
    TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
    assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
    assert reply["dispatch_id"] == dispatch["dispatch_id"]
    reply
  end

  describe "a verify dispatch" do
    test "is accepted, run over its story and PR with its budgets, and answered verify@1", ctx do
      TestLoopctl.put(:agent_result_replies, [:ok])
      result = %{"verdict" => "reject", "findings" => ["AC-1 fails"], "head_sha" => @head}

      {pid, topic} =
        running_control(ctx,
          triage_run: fake_run({:agent_result, {"verify", 1}, result})
        )

      assert "verify" in Control.kinds()
      dispatch = verify_dispatch()
      assert accept!(topic, dispatch)["decision"] == "accepted"

      assert_receive {:ran, subject, "mkreyman/fixture", opts}, 5_000
      assert subject["verify"] == %{"pr_number" => 7, "head_sha" => @head}
      assert subject["story"]["id"] == dispatch["story_id"]
      assert subject["branch"] == "loop/story-1"
      assert subject["base_branch"] == "master"
      assert %{id: "verify", version: 1} = opts[:template]
      assert opts[:wall_clock_s] == 30
      assert opts[:max_turns] == 7

      payload = next_result()

      assert payload == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 2,
               "spec" => @spec_ref,
               "result" => result
             }

      assert Contract.validate("RunnerAgentResultMessage", payload) == :ok
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 200
      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)
      # Settled: nothing is kept for a restart to send again.
      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "with no verify object is refused other, and nothing runs", ctx do
      {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

      reply = accept!(topic, Map.delete(verify_dispatch(), "verify"))
      assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
      assert detail == "the verify dispatch carries no verify object"
      refute_receive {:ran, _, _, _}, 300
    end

    test "with a head that is not a full commit id is refused other, by the contract", ctx do
      {_pid, topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

      dispatch = verify_dispatch(%{"verify" => %{"pr_number" => 7, "head_sha" => "abc123"}})

      capture_log(fn ->
        assert %{"decision" => "refused", "reason" => "other", "detail" => detail} =
                 accept!(topic, dispatch)

        send(self(), {:detail, detail})
      end)

      # The vendored schema refuses it before the runner's own check (TriageRun.subject/2,
      # covered in VerifyRunTest) is reached.
      assert_received {:detail, detail}
      assert detail =~ "RunnerDispatch.verify.head_sha"
      refute_receive {:ran, _, _, _}, 300
    end

    test "whose run produced no result sends nothing", ctx do
      capture_log(fn ->
        {pid, topic} =
          running_control(ctx,
            triage_run: fake_run({:no_result, "the session stated no verdict"})
          )

        assert accept!(topic, verify_dispatch())["decision"] == "accepted"
        assert_receive {:ran, _, _, _}, 5_000
        :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 5_000)
        refute_receive {:test_loopctl, {:agent_result, _}}, 500
        refute_receive {:test_loopctl, {:triage_verdict, _}}, 100
      end)

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end
  end

  describe "a verify run whose process dies" do
    # The run announces its directory, leaves `on_disk` there, and exits without returning.
    defp dying_run(on_disk) do
      fn config, _subject, _repo, opts ->
        run_id = Session.uuid4()
        run_dir = Path.join(config.runs_dir, "verify-#{run_id}")
        File.mkdir_p!(run_dir)

        RunState.update(run_dir, %{
          "run_id" => run_id,
          "kind" => "verify",
          "status" => "running"
        })

        Keyword.fetch!(opts, :on_start).(%{run_id: run_id, run_dir: run_dir})
        on_disk.(run_dir)
        exit(:killed_mid_run)
      end
    end

    test "with no verdict on disk sends nothing, never a triage incomplete", ctx do
      capture_log(fn ->
        {pid, topic} = running_control(ctx, triage_run: dying_run(fn _run_dir -> :ok end))
        assert accept!(topic, verify_dispatch())["decision"] == "accepted"
        :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 5_000)
        refute_receive {:test_loopctl, {:triage_verdict, _}}, 500
        refute_receive {:test_loopctl, {:agent_result, _}}, 100
      end)

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "after its session stated a verdict at the recorded head sends THAT verdict", ctx do
      TestLoopctl.put(:agent_result_replies, [:ok])
      dispatch = verify_dispatch()

      final =
        "Done.\n\n```json\n" <> ~s({"verdict":"reject","findings":["AC-1 fails"]}) <> "\n```"

      leave = fn run_dir ->
        RunState.update(run_dir, %{"judged_head" => @head})

        File.write!(
          Path.join(run_dir, "stdout.ndjson"),
          Jason.encode!(%{"type" => "result", "subtype" => "success", "result" => final}) <> "\n"
        )
      end

      capture_log(fn ->
        {_pid, topic} = running_control(ctx, triage_run: dying_run(leave))
        assert accept!(topic, dispatch)["decision"] == "accepted"

        assert next_result() == %{
                 "dispatch_id" => dispatch["dispatch_id"],
                 "claim_epoch" => 2,
                 "spec" => @spec_ref,
                 "result" => %{
                   "verdict" => "reject",
                   "findings" => ["AC-1 fails"],
                   "head_sha" => @head
                 }
               }

        refute_receive {:test_loopctl, {:triage_verdict, _}}, 300
      end)
    end
  end

  describe "a verify verdict across a restart" do
    test "the one recorded on disk is resent by the next Control, unchanged", ctx do
      TestLoopctl.put(:agent_result_replies, [:ok])
      dispatch = verify_dispatch()
      result = %{"verdict" => "pass", "findings" => [], "head_sha" => @head}

      {:ok, recorded} =
        AgentResult.message(
          Map.take(dispatch, ["dispatch_id", "claim_epoch"]),
          {"verify", 1},
          result
        )

      run_dir = Path.join(ctx.config.runs_dir, "verify-#{Session.uuid4()}")
      File.mkdir_p!(run_dir)
      :ok = PendingVerdicts.write(run_dir, recorded)

      {pid, _topic} = running_control(ctx, triage_run: fake_run({:no_result, "unused"}))

      assert next_result() == recorded
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
      # Settled once loopctl recorded it: deleted, so no third Control sends it again.
      :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
    end

    test "already_recorded is permanent: given up, never resent, not kept", ctx do
      assert AgentResult.classify("already_recorded") == :permanent
      TestLoopctl.put(:agent_result_replies, [{:error, %{reason: "already_recorded"}}])
      dispatch = verify_dispatch()
      result = %{"verdict" => "pass", "findings" => [], "head_sha" => @head}

      log =
        capture_log(fn ->
          {pid, topic} =
            running_control(ctx,
              triage_run: fake_run({:agent_result, {"verify", 1}, result}),
              triage_verdict_retry_ms: 100
            )

          assert accept!(topic, dispatch)["decision"] == "accepted"
          next_result()
          refute_receive {:test_loopctl, {:agent_result, _}}, 800
          assert Control.info(pid).triage_verdict_backlog == 0
        end)

      assert log =~
               "giving up on the agent_result for dispatch #{dispatch["dispatch_id"]} " <>
                 "(already_recorded)"

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "rate_limited is sent again, unchanged, as every agent_result is", ctx do
      TestLoopctl.put(:agent_result_replies, [{:error, %{reason: "rate_limited"}}, :ok])
      result = %{"verdict" => "pass", "findings" => [], "head_sha" => @head}

      {pid, topic} =
        running_control(ctx,
          triage_run: fake_run({:agent_result, {"verify", 1}, result}),
          triage_verdict_retry_ms: 100
        )

      assert accept!(topic, verify_dispatch())["decision"] == "accepted"
      first = next_result()
      assert next_result() == first
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
    end
  end
end
