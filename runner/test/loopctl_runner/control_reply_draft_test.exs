defmodule LoopctlRunner.ControlReplyDraftTest do
  @moduledoc """
  US-48.9, the runner half of the reply drafter: a `reply_draft` dispatch is accepted on the
  triage path (a detached tree, no branch), its session's final fenced JSON block becomes an
  `agent_result` naming `reply_draft@1`, and that message is settled the way a verdict is —
  except that a draft which produced no result sends nothing at all.
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

  @moduletag timeout: 90_000

  @spec_ref %{"id" => "reply_draft", "version" => 1}

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-reply-draft")
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
    fake = Path.join(root, "fake")
    File.mkdir_p!(fake)

    {:ok,
     config: %{config!(root) | control: control},
     root: root,
     fake: fake,
     run_supervisor: start_supervised!(Task.Supervisor)}
  end

  defp running_control(ctx, fake_vars, opts \\ []) do
    restore = fake_env!(ctx.fake, [{"FAKE_AGENTS", "busy"} | fake_vars])
    on_exit(fn -> restore.() end)
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

  # A reply_draft dispatch as loopctl sends one: the `triage` object carries the fenced report,
  # and the branch is the base itself — a :draft writes no branch, so none of the runner's
  # prefixes is asked of it.
  defp draft_dispatch(overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => Session.uuid4(),
        "kind" => "reply_draft",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "master",
        "claim_epoch" => 3,
        "wall_clock_seconds" => 30,
        "max_turns" => 5,
        "triage" => %{
          "record_id" => Session.uuid4(),
          "issue_number" => 846,
          "html_url" => nil,
          "truncated" => false,
          "untrusted" => "<<<UNTRUSTED reported_issue n0nce>>>\n| it crashes\n<<<END n0nce>>>"
        }
      },
      overrides
    )
  end

  # The CLI's final stream-json line, carrying `text` as the session's final message.
  defp result_line(text),
    do: Jason.encode!(%{"type" => "result", "subtype" => "success", "result" => text})

  defp final(result), do: "Read lib/upload.ex.\n\n```json\n#{Jason.encode!(result)}\n```"

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

  describe "a reply_draft dispatch" do
    test "is accepted on a plain base branch, runs, and its draft reaches loopctl as agent_result",
         ctx do
      TestLoopctl.put(:agent_result_replies, [:ok])
      body = "Thanks for the report. We can see the upload fails on a quoted name."

      {pid, topic} =
        running_control(ctx, [
          {"FAKE_CLAUDE_MODE", "stream"},
          {"FAKE_RESULT_LINE", result_line(final(%{"body" => body}))}
        ])

      assert "reply_draft" in Control.kinds()
      dispatch = draft_dispatch()
      assert accept!(topic, dispatch)["decision"] == "accepted"

      payload = next_result()

      assert payload == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "spec" => @spec_ref,
               "result" => %{"body" => body}
             }

      assert Contract.validate("RunnerAgentResultMessage", payload) == :ok
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 200
      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)

      assert [{_dir, %{"kind" => "reply_draft", "status" => "agent_result"}}] =
               RunState.all(ctx.config.runs_dir)
    end

    test "whose result fails the schema sends nothing, and the run counts as failed", ctx do
      log =
        capture_log(fn ->
          {pid, topic} =
            running_control(ctx, [
              {"FAKE_CLAUDE_MODE", "stream"},
              {"FAKE_RESULT_LINE", result_line(final(%{"body" => "   "}))}
            ])

          dispatch = draft_dispatch()
          assert accept!(topic, dispatch)["decision"] == "accepted"

          :ok =
            wait_until(
              fn ->
                match?(
                  [{_, %{"status" => "failed:no_result"}}],
                  RunState.all(ctx.config.runs_dir)
                )
              end,
              10_000
            )

          refute_receive {:test_loopctl, {:agent_result, _}}, 500
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 100
          assert Control.info(pid).triage_verdict_backlog == 0
        end)

      assert log =~ "produced no result to send"
      assert log =~ "fails its spec's schema"
      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "whose session ends with no fenced block sends nothing", ctx do
      capture_log(fn ->
        {_pid, topic} =
          running_control(ctx, [
            {"FAKE_CLAUDE_MODE", "stream"},
            {"FAKE_RESULT_LINE", result_line("I could not find the upload code.")}
          ])

        assert accept!(topic, draft_dispatch())["decision"] == "accepted"

        :ok =
          wait_until(
            fn ->
              match?([{_, %{"status" => "failed:no_result"}}], RunState.all(ctx.config.runs_dir))
            end,
            10_000
          )

        refute_receive {:test_loopctl, {:agent_result, _}}, 500
      end)
    end
  end

  describe "the agent_result on the wire" do
    defp send_result(pid, dispatch, body) do
      binding = Map.take(dispatch, ["dispatch_id", "claim_epoch"])

      send(
        pid,
        {:triage_outcome, binding, %{run_dir: nil},
         {:agent_result, {"reply_draft", 1}, %{"body" => body}}}
      )
    end

    test "an ack says whether it recorded the result or replayed one", ctx do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)
      TestLoopctl.put(:agent_result_replies, [:replayed])

      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          send_result(pid, draft_dispatch(), "Thanks.")
          assert %{"spec" => @spec_ref} = next_result()
          :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)
        end)

      assert log =~ "loopctl recorded the agent_result at "
      assert log =~ "(replayed: true)"
    end

    test "already_recorded is permanent: given up, never resent, not kept for a restart", ctx do
      assert AgentResult.classify("already_recorded") == :permanent
      TestLoopctl.put(:agent_result_replies, [{:error, %{reason: "already_recorded"}}])
      dispatch = draft_dispatch()

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          send_result(pid, dispatch, "Thanks.")
          next_result()
          refute_receive {:test_loopctl, {:agent_result, _}}, 800
          assert Control.info(pid).triage_verdict_backlog == 0
        end)

      assert log =~
               "giving up on the agent_result for dispatch #{dispatch["dispatch_id"]} " <>
                 "(already_recorded)"

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "rate_limited waits out the refill and is sent again, unchanged", ctx do
      TestLoopctl.put(:agent_result_replies, [{:error, %{reason: "rate_limited"}}, :ok])

      {pid, _topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

      send_result(pid, draft_dispatch(), "Thanks.")

      first = next_result()
      assert next_result() == first
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
      refute_receive {:test_loopctl, {:agent_result, _}}, 500
    end
  end
end
