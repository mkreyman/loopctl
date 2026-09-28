defmodule LoopctlRunner.ControlReviewTest do
  @moduledoc """
  The review half of the accept path (contract 1.21.0): a `review` dispatch declared, accepted and
  run read-only, and what its run sends back — its findings, its one verdict and its
  `session_ended` — over the wire, through every refusal the contract publishes for them.

  Most tests drive the report side the way a run reaches Control: `{:run_stage, binding,
  {:finished, summary}}` from a run directory holding what a session stated. The first ones run a
  real review session end to end, with the fake CLI.
  """

  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    Contract,
    Control,
    ControlConfig,
    DispatchRun,
    Owner,
    Reaper,
    ReviewJudgements,
    ReviewRun,
    RunState,
    ScratchRun,
    Session,
    Story,
    TestLoopctl,
    Worktree
  }

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 90_000

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-review")
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

    # The checkpoint another machine pushed to the story's branch, which this checkout lacks.
    origin = git_repo!(Path.join(root, "origin"))
    repo = Path.join(root, "repo")
    git!(root, ["clone", "-q", origin, repo])
    git!(repo, ["config", "core.hooksPath", "/dev/null"])
    git!(origin, ["checkout", "-q", "-b", "implementer/story-1"])
    File.write!(Path.join(origin, "app.ex"), "the change under review\n")
    git!(origin, ["add", "app.ex"])
    git!(origin, ["commit", "-q", "-m", "checkpoint 1"])
    commit = git!(origin, ["rev-parse", "HEAD"])
    tree = git!(origin, ["rev-parse", "HEAD^{tree}"])
    git!(origin, ["checkout", "-q", "master"])

    fake = Path.join(root, "fake")
    File.mkdir_p!(fake)

    {:ok,
     config: %{config!(root) | control: control},
     root: root,
     fake: fake,
     commit: commit,
     tree: tree,
     run_supervisor: start_supervised!(Task.Supervisor)}
  end

  defp start_control(ctx, opts) do
    test = self()

    opts =
      Keyword.merge(
        [
          config: ctx.config,
          on_fatal: &send(test, {:fatal, &1}),
          run_supervisor: ctx.run_supervisor,
          trace_poll_ms: 200,
          stage_retry_ms: 50
        ],
        opts
      )

    {:ok, pid} = GenServer.start(Control, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
    {pid, "runner:" <> TestLoopctl.get(:runner_id)}
  end

  defp running_control(ctx, fake_vars, opts \\ []) do
    restore =
      fake_env!(ctx.fake, [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_AGENTS", "busy"} | fake_vars])

    on_exit(fn -> restore.() end)
    start_control(ctx, opts)
  end

  defp review_dispatch(ctx, overrides \\ %{}) do
    story_id = Session.uuid4()

    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => story_id,
        "kind" => "review",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        # The implementer's branch, outside this machine's `branch_prefixes` (`loop/`): a review
        # only fetches it, so that is no reason to refuse one.
        "branch" => "implementer/story-1",
        "claim_epoch" => 3,
        "wall_clock_seconds" => 30,
        "max_turns" => 5,
        "story" => %{"id" => story_id, "title" => "Add a greeting"},
        "review" => %{
          "review_id" => Session.uuid4(),
          "round" => 1,
          "checkpoint_id" => Session.uuid4(),
          "checkpoint_seq" => 1,
          "commit_sha" => ctx.commit,
          "tree_sha" => ctx.tree
        }
      },
      overrides
    )
  end

  defp next(event, timeout \\ 10_000) do
    receive do
      {:test_loopctl, {^event, payload}} -> payload
    after
      timeout -> flunk("no #{event} within #{timeout}ms")
    end
  end

  # A run directory as a review run leaves it: its state naming the dispatch and the review, and
  # what its session stated, as the commands record it.
  defp review_run_dir!(ctx, dispatch, judgements, state \\ %{}) do
    dir = Path.join(ctx.config.runs_dir, "review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    RunState.update(
      dir,
      DispatchRun.binding(dispatch)
      |> Map.merge(%{
        "run_id" => Session.uuid4(),
        "kind" => "review",
        "review" => dispatch["review"],
        "status" => "succeeded"
      })
      |> Map.merge(state)
    )

    lines = Enum.map_join(judgements, "", &(JSON.encode!(&1) <> "\n"))
    File.write!(ReviewJudgements.judgements_file(dir), lines)
    dir
  end

  defp finding(body, severity \\ "high"),
    do: %{"kind" => "finding", "body" => body, "severity" => severity}

  defp verdict(body \\ "one defect"), do: %{"kind" => "verdict", "body" => body}

  # What a review run tells its Control when it ends.
  defp finished(pid, dispatch, dir, status \\ "succeeded", extra \\ %{}) do
    send(
      pid,
      {:run_stage, DispatchRun.binding(dispatch),
       {:finished, Map.merge(%{kind: "review", run_dir: dir, status: status}, extra)}}
    )
  end

  defp settled(pid), do: wait_until(fn -> Control.info(pid).review_judgements_pending == 0 end)

  defp end_recorded(dir),
    do: fn -> match?({:ok, %{"terminal_reported" => true}}, RunState.read(dir)) end

  test "the join declares review, from the one list the kind check reads", ctx do
    {_pid, _topic} = start_control(ctx, [])
    runner_id = TestLoopctl.get(:runner_id)
    assert_receive {:test_loopctl, {:join, ^runner_id, join}}, 5_000

    assert join["kinds"] == Control.kinds()
    assert "review" in join["kinds"]
    assert Contract.validate("RunnerJoin", join) == :ok
  end

  describe "an accepted review" do
    test "runs read-only on the checkpoint, sends its findings, its verdict, then session_ended",
         ctx do
      TestLoopctl.put(:session_ended_replies, [:review])

      {pid, topic} =
        running_control(ctx, [
          {"FAKE_REVIEW_FINDINGS", "2"},
          {"FAKE_REVIEW_VERDICT", "Two defects."},
          {"FAKE_REVIEW_AFTER", "1"},
          {"FAKE_PROBE_CMD", "git rev-parse HEAD; git symbolic-ref -q HEAD || echo detached"}
        ])

      dispatch = review_dispatch(ctx)
      id = dispatch["dispatch_id"]
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert next(:dispatch_reply) ==
               %{"dispatch_id" => id, "claim_epoch" => 3, "decision" => "accepted"}

      first = next(:review_finding, 20_000)
      second = next(:review_finding)
      last = next(:review_verdict)

      assert %{
               "dispatch_id" => ^id,
               "claim_epoch" => 3,
               "client_seq" => 0,
               "severity" => "high",
               "location" => "lib/app.ex:1"
             } = first

      assert first["body"] =~ "defect 1"
      assert %{"client_seq" => 1, "location" => "lib/app.ex:2"} = second

      assert last == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "client_seq" => 2,
               "body" => "Two defects."
             }

      # The slot is freed by session_ended, sent after the verdict, not by the verdict.
      assert next(:session_ended) == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "reason" => "completed"
             }

      # The session read the checkpoint itself, detached.
      assert File.read!(Path.join(ctx.fake, "probe")) == "#{ctx.commit}\ndetached\n"

      :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 10_000)
      [{dir, state}] = RunState.all(ctx.config.runs_dir)
      :ok = wait_until(end_recorded(dir))
      assert ReviewJudgements.settled(dir) == 3
      assert state["kind"] == "review"

      # A review reports no stage, and nothing stated after the verdict is sent.
      refute_receive {:test_loopctl, {:stage, _}}, 300
      refute_receive {:test_loopctl, {:review_finding, _}}, 300
      assert Control.info(pid).session_ended_pending == 0
    end

    test "a review dispatch without its review or its story is refused other", ctx do
      {_pid, topic} = start_control(ctx, [])

      capture_log(fn ->
        for {field, detail} <- [
              {"review", "the dispatch carries no review"},
              {"story", "the dispatch carries no story"}
            ] do
          dispatch = ctx |> review_dispatch() |> Map.delete(field)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert %{"decision" => "refused", "reason" => "other", "detail" => ^detail} =
                   next(:dispatch_reply)
        end
      end)
    end

    test "a review is held to plain ref names, not to the prefixes of the branches this machine writes",
         ctx do
      {_pid, topic} = start_control(ctx, [])

      capture_log(fn ->
        bad = review_dispatch(ctx, %{"branch" => "implementer/../x"})
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", bad)

        assert %{"decision" => "refused", "reason" => "branch_not_allowed"} =
                 next(:dispatch_reply)

        # The same branch on a dispatch that WRITES it is held to the prefixes; the review of it
        # is accepted in the first test of this file.
        implement = ctx |> review_dispatch(%{"kind" => "implement"}) |> Map.delete("review")
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", implement)

        assert %{"decision" => "refused", "reason" => "branch_not_allowed", "detail" => detail} =
                 next(:dispatch_reply)

        assert detail =~ "is outside"
      end)
    end
  end

  describe "delivering a review's judgements" do
    test "a finding whose reply is lost is resent as the same bytes after a rejoin", ctx do
      TestLoopctl.put(:review_finding_replies, [:none, :replayed, :ok])
      TestLoopctl.put(:review_verdict_replies, [:none, :replayed])
      dispatch = review_dispatch(ctx)

      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
          finished(pid, dispatch, dir)

          lost = next(:review_finding)
          assert lost["client_seq"] == 0
          rejoin(pid)
          assert next(:review_finding) == lost
          assert %{"client_seq" => 1, "body" => "two"} = next(:review_finding)

          lost_verdict = next(:review_verdict)
          rejoin(pid)
          assert next(:review_verdict) == lost_verdict

          assert %{"reason" => "completed"} = next(:session_ended)
          :ok = settled(pid)
          :ok = wait_until(end_recorded(dir))
          refute_receive {:test_loopctl, {:review_finding, _}}, 300
        end)

      assert log =~ "loopctl recorded review_finding 0 (replayed: true)"
      assert log =~ "loopctl recorded review_verdict 2 (replayed: true)"
    end

    test "a rate-limited judgement waits the interval it names, then goes again", ctx do
      limited = {:error, %{reason: "rate_limited", min_interval_ms: 400}}
      TestLoopctl.put(:review_finding_replies, [limited, :ok])
      dispatch = review_dispatch(ctx)

      {pid, _topic} = start_control(ctx, [])
      dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
      finished(pid, dispatch, dir)

      first = next(:review_finding)
      sent = System.monotonic_time(:millisecond)
      assert next(:review_finding) == first
      assert System.monotonic_time(:millisecond) - sent >= 400
      assert %{"client_seq" => 1} = next(:review_verdict)
      assert next(:session_ended)["reason"] == "completed"
    end

    test "a halted tenant gets the same bytes again until the halt is lifted", ctx do
      halted = {:error, %{reason: "tenant_halted"}}
      TestLoopctl.put(:review_verdict_replies, [halted, halted, :ok])
      dispatch = review_dispatch(ctx)

      {dir, _log} =
        with_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [verdict()])
          finished(pid, dispatch, dir)
          first = next(:review_verdict)
          assert next(:review_verdict, 5_000) == first
          assert next(:review_verdict, 5_000) == first
          assert next(:session_ended)["reason"] == "completed"
          :ok = settled(pid)
          dir
        end)

      assert ReviewJudgements.settled(dir) == 1
    end

    test "internal_error is resent with no ceiling until it lands, and nothing after it goes first",
         ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:review_finding_replies, [internal, internal, internal])
      dispatch = review_dispatch(ctx)
      id = dispatch["dispatch_id"]

      {dir, log} =
        with_log(fn ->
          # The ceiling other messages give up at does not apply: skipping a finding would let
          # the verdict complete the round without it.
          {pid, _topic} = start_control(ctx, internal_error_attempts: 2)
          dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
          finished(pid, dispatch, dir)
          first = next(:review_finding)
          for _ <- 1..3, do: assert(next(:review_finding, 5_000) == first)
          assert %{"client_seq" => 1} = next(:review_finding)
          assert %{"client_seq" => 2} = next(:review_verdict)
          assert next(:session_ended)["reason"] == "completed"
          :ok = settled(pid)
          :ok = wait_until(end_recorded(dir))
          dir
        end)

      assert log =~
               "loopctl refused review_finding 0 for dispatch #{id} as internal_error; resending"

      assert ReviewJudgements.settled(dir) == 3
    end

    test "a reply this build cannot read is resent as the same bytes, never skipped", ctx do
      TestLoopctl.put(:review_finding_replies, [{:error, %{reason: "something_new"}}])
      dispatch = review_dispatch(ctx)

      {dir, log} =
        with_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
          finished(pid, dispatch, dir)
          first = next(:review_finding)
          assert next(:review_finding, 5_000) == first
          assert %{"client_seq" => 1} = next(:review_verdict)
          assert next(:session_ended)["reason"] == "completed"
          :ok = settled(pid)
          dir
        end)

      assert log =~ "[error]"
      assert log =~ "with a reply this build (contract #{Contract.version()}) does not handle"
      assert ReviewJudgements.settled(dir) == 2
    end

    test "a verdict refused internal_error is resent until it lands, and marks nothing", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:review_verdict_replies, [internal, internal, internal])
      dispatch = review_dispatch(ctx)

      {dir, _log} =
        with_log(fn ->
          {pid, _topic} =
            start_control(ctx, internal_error_attempts: 2, terminal_internal_error_attempts: 2)

          dir = review_run_dir!(ctx, dispatch, [verdict()])
          finished(pid, dispatch, dir)
          first = next(:review_verdict)
          for _ <- 1..3, do: assert(next(:review_verdict, 5_000) == first)
          assert next(:session_ended)["reason"] == "completed"
          :ok = settled(pid)
          :ok = wait_until(end_recorded(dir))
          dir
        end)

      assert ReviewJudgements.settled(dir) == 1
      refute Map.has_key?(elem(RunState.read(dir), 1), "review_verdict_undelivered")
    end

    test "a head that will not go within the retry budget gives up all that is owed, the verdict too",
         ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:review_finding_replies, List.duplicate(internal, 200))
      dispatch = review_dispatch(ctx)
      id = dispatch["dispatch_id"]

      {dir, log} =
        with_log(fn ->
          {pid, _topic} = start_control(ctx, judgement_retry_budget_ms: 400)
          dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
          finished(pid, dispatch, dir)
          assert %{"client_seq" => 0} = next(:review_finding)

          # The slot is freed once the budget is spent, not held for as long as loopctl refuses.
          assert next(:session_ended, 5_000)["reason"] == "completed"
          :ok = settled(pid)
          :ok = wait_until(end_recorded(dir))
          dir
        end)

      # Only the head was ever sent: never a later finding, and never the verdict past it.
      refute_received {:test_loopctl, {:review_verdict, _}}
      refute_received {:test_loopctl, {:review_finding, %{"client_seq" => 1}}}

      assert log =~
               "the review of dispatch #{id} gives up: its review_finding 0 did not go within " <>
                 "400ms of its first failure (as internal_error)"

      assert ReviewJudgements.settled(dir) == 3

      assert {:ok, %{"review_verdict_undelivered" => why}} = RunState.read(dir)
      assert why == "gave up after 400ms on the review_finding 0: as internal_error"
    end

    test "rate limiting does not slow the resend of a judgement refused internal_error", ctx do
      # Counted apart: six rate-limited refusals first used to start the transient backoff at
      # 2^6 times the retry interval, over three seconds here, instead of at the interval.
      limited = {:error, %{reason: "rate_limited", min_interval_ms: 10}}
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:review_finding_replies, List.duplicate(limited, 6) ++ [internal, :ok])
      dispatch = review_dispatch(ctx)

      capture_log(fn ->
        {pid, _topic} = start_control(ctx, [])
        dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
        finished(pid, dispatch, dir)
        first = next(:review_finding)
        for _ <- 1..6, do: assert(next(:review_finding) == first)
        refused_at = System.monotonic_time(:millisecond)
        assert next(:review_finding) == first
        assert System.monotonic_time(:millisecond) - refused_at < 1_000
        assert %{"client_seq" => 1} = next(:review_verdict)
        assert next(:session_ended)["reason"] == "completed"
        :ok = settled(pid)
      end)
    end

    test "judgements that cannot be composed are composed again, with nothing sent behind them",
         ctx do
      dispatch = review_dispatch(ctx)

      log =
        capture_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
          # A composition that cannot be read, as a failing disk leaves one: a directory.
          File.mkdir_p!(ReviewJudgements.messages_file(dir))
          finished(pid, dispatch, dir)

          refute_receive {:test_loopctl, {:session_ended, _}}, 700
          refute_received {:test_loopctl, {:review_finding, _}}
          # Nothing records the run's end, so a Control starting over it composes it too.
          refute Map.has_key?(elem(RunState.read(dir), 1), "terminal_reported")

          File.rmdir!(ReviewJudgements.messages_file(dir))
          assert %{"client_seq" => 0} = next(:review_finding)
          assert %{"client_seq" => 1} = next(:review_verdict)
          assert next(:session_ended)["reason"] == "completed"
          :ok = wait_until(end_recorded(dir))
        end)

      assert log =~ "judgements could not be composed"
    end

    test "a composition that stays unreadable past the budget is given up, and the slot freed",
         ctx do
      dispatch = review_dispatch(ctx)

      {dir, log} =
        with_log(fn ->
          {pid, _topic} = start_control(ctx, judgement_retry_budget_ms: 300)
          dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
          File.mkdir_p!(ReviewJudgements.messages_file(dir))
          finished(pid, dispatch, dir)
          assert next(:session_ended, 5_000)["reason"] == "completed"
          :ok = wait_until(end_recorded(dir))
          dir
        end)

      refute_received {:test_loopctl, {:review_finding, _}}
      refute_received {:test_loopctl, {:review_verdict, _}}
      assert log =~ "gives up: its composition did not go within 300ms"
      assert {:ok, %{"review_verdict_undelivered" => why}} = RunState.read(dir)
      assert why =~ "gave up after 300ms on the composition"
    end

    test "a claim-ending refusal ends it: nothing more is sent but its session_ended", ctx do
      # Every code the contract says ends the claim a finding ran under (1.22.0), read from the
      # vendored table rather than typed here.
      reasons = Contract.claim_ending_errors("review_finding")
      assert "review_closed" in reasons and "stale_claim_epoch" in reasons

      for reason <- reasons do
        TestLoopctl.put(:review_finding_replies, [{:error, %{reason: reason}}])
        dispatch = review_dispatch(ctx)

        {dir, log} =
          with_log(fn ->
            {pid, _topic} = start_control(ctx, [])
            dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
            finished(pid, dispatch, dir)
            assert %{"client_seq" => 0} = next(:review_finding)

            # The round is over on loopctl's side; the session's own end still goes, as it is.
            assert next(:session_ended) == %{
                     "dispatch_id" => dispatch["dispatch_id"],
                     "claim_epoch" => 3,
                     "reason" => "completed"
                   }

            refute_receive {:test_loopctl, {:review_finding, _}}, 300
            refute_receive {:test_loopctl, {:review_verdict, _}}, 100
            :ok = settled(pid)
            :ok = wait_until(end_recorded(dir))
            GenServer.stop(pid)
            dir
          end)

        assert log =~ "(#{reason}), which ends the claim it ran under", reason
        # Recorded, so a Control starting over the run does not send them again.
        assert ReviewJudgements.settled(dir) == 3, reason
        refute Map.has_key?(elem(RunState.read(dir), 1), "review_verdict_undelivered"), reason
      end
    end

    test "a refusal of the verdict about the review ends it as well", ctx do
      TestLoopctl.put(:review_verdict_replies, [{:error, %{reason: "review_closed"}}])
      dispatch = review_dispatch(ctx)

      capture_log(fn ->
        {pid, _topic} = start_control(ctx, [])
        dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
        finished(pid, dispatch, dir)
        assert %{"client_seq" => 0} = next(:review_finding)
        verdict = next(:review_verdict)
        assert next(:session_ended)["reason"] == "completed"
        refute_receive {:test_loopctl, {:review_verdict, ^verdict}}, 300
        :ok = settled(pid)
      end)
    end

    test "a refusal about the message drops it, and the next judgement still goes", ctx do
      # 1.22.0's two per-message codes among them: never resent, never the claim's end.
      for reason <- ~w(secret_blocked idempotency_key_reused claim_epoch_mismatch
                       wrong_dispatch_kind) do
        TestLoopctl.put(:review_finding_replies, [{:error, %{reason: reason}}, :ok])
        dispatch = review_dispatch(ctx)

        log =
          capture_log(fn ->
            {pid, _topic} = start_control(ctx, [])
            dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
            finished(pid, dispatch, dir)
            assert %{"client_seq" => 0} = next(:review_finding)
            assert %{"client_seq" => 1, "body" => "two"} = next(:review_finding)
            assert %{"client_seq" => 2} = next(:review_verdict)
            assert next(:session_ended)["reason"] == "completed"
            :ok = settled(pid)
            GenServer.stop(pid)
          end)

        assert log =~ "(#{reason}), and no resend can move that", reason
      end
    end

    test "a verdict refused for good is recorded for the operator, and sends nothing else", ctx do
      TestLoopctl.put(:review_verdict_replies, [{:error, %{reason: "secret_blocked"}}])
      dispatch = review_dispatch(ctx)
      id = dispatch["dispatch_id"]

      {dir, log} =
        with_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()])
          finished(pid, dispatch, dir)
          assert %{"client_seq" => 0} = next(:review_finding)
          verdict = next(:review_verdict)
          assert %{"client_seq" => 1} = verdict
          assert next(:session_ended)["reason"] == "completed"
          refute_receive {:test_loopctl, {:review_verdict, ^verdict}}, 300
          :ok = settled(pid)
          :ok = wait_until(end_recorded(dir))
          dir
        end)

      assert log =~
               "loopctl refused review_verdict 1 for dispatch #{id} (secret_blocked), and no " <>
                 "resend can move that: the round has no verdict from this review"

      assert ReviewJudgements.settled(dir) == 2

      assert {:ok, %{"review_verdict_undelivered" => "refused secret_blocked"}} =
               RunState.read(dir)
    end

    test "a review that exited 0 stating no verdict ends completed: its session did", ctx do
      dispatch = review_dispatch(ctx)

      capture_log(fn ->
        {pid, _topic} = start_control(ctx, [])
        dir = review_run_dir!(ctx, dispatch, [finding("one")])
        finished(pid, dispatch, dir)
        assert %{"client_seq" => 0} = next(:review_finding)
        assert next(:session_ended)["reason"] == "completed"
        :ok = settled(pid)
      end)
    end

    test "a review that escalated is logged as an error with what it said, and the reason sent",
         ctx do
      dispatch = review_dispatch(ctx)

      log =
        capture_log(fn ->
          {pid, _topic} = start_control(ctx, [])
          dir = review_run_dir!(ctx, dispatch, [verdict()], %{"status" => "escalated"})

          finished(pid, dispatch, dir, "escalated", %{
            escalations: ["the commit will not check out"]
          })

          assert %{"client_seq" => 0} = next(:review_verdict)
          assert next(:session_ended)["reason"] == "completed"
          :ok = settled(pid)
        end)

      assert log =~ "[error]"

      assert log =~
               "the review session escalated, which a review cannot do; its session_ended is " <>
                 "completed. It said: the commit will not check out"
    end

    test "nothing stated after the verdict is sent, and the session_ended goes last", ctx do
      dispatch = review_dispatch(ctx)

      capture_log(fn ->
        {pid, _topic} = start_control(ctx, [])
        dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict(), finding("late")])
        finished(pid, dispatch, dir)

        events =
          for _ <- 1..3 do
            assert_receive {:test_loopctl, {event, _payload}}
                           when event in [:review_finding, :review_verdict, :session_ended],
                           5_000

            event
          end

        assert events == [:review_finding, :review_verdict, :session_ended]
        refute_receive {:test_loopctl, {:review_finding, _}}, 300
        :ok = settled(pid)
      end)
    end

    test "a review ended with nothing stated still frees its slot", ctx do
      dispatch = review_dispatch(ctx)

      {pid, _topic} = start_control(ctx, [])
      dir = review_run_dir!(ctx, dispatch, [], %{"status" => "failed"})
      finished(pid, dispatch, dir, "failed")

      assert next(:session_ended) ==
               Map.put(
                 Map.take(DispatchRun.binding(dispatch), ~w(dispatch_id claim_epoch)),
                 "reason",
                 "crashed"
               )

      refute_receive {:test_loopctl, {:review_finding, _}}, 300
      :ok = settled(pid)
    end
  end

  describe "a Control starting over a review run" do
    test "sends what the run owes from the composed bytes, and nothing already settled", ctx do
      dispatch = review_dispatch(ctx)
      dir = review_run_dir!(ctx, dispatch, [finding("one"), finding("two"), verdict()])
      {:ok, composed} = ReviewJudgements.compose(dir)
      :ok = ReviewJudgements.settle(dir, 1)

      # Recorded differently after the composition — a finding before the verdict: a restart must
      # neither number it nor renumber anything, or the verdict would go out on another number.
      lines =
        Enum.map_join(
          [finding("one"), finding("two"), finding("sneaked"), verdict()],
          "",
          &(JSON.encode!(&1) <> "\n")
        )

      File.write!(ReviewJudgements.judgements_file(dir), lines)

      capture_log(fn ->
        {pid, _topic} = start_control(ctx, [])
        assert next(:review_finding) == composed |> Enum.at(1) |> elem(1)
        assert next(:review_verdict) == composed |> Enum.at(2) |> elem(1)
        assert next(:session_ended)["reason"] == "completed"
        :ok = wait_until(end_recorded(dir))
        :ok = settled(pid)
        refute_receive {:test_loopctl, {:review_finding, _}}, 300
      end)
    end

    test "composes a run whose task died before it could, and reports it crashed", ctx do
      dispatch = review_dispatch(ctx)
      dir = review_run_dir!(ctx, dispatch, [finding("one"), verdict()], %{"status" => "running"})
      refute File.exists?(ReviewJudgements.messages_file(dir))

      capture_log(fn ->
        {_pid, _topic} = start_control(ctx, [])
        assert %{"client_seq" => 0} = next(:review_finding)
        assert %{"client_seq" => 1} = next(:review_verdict)
        assert next(:session_ended)["reason"] == "crashed"
        :ok = wait_until(end_recorded(dir))
      end)

      assert File.exists?(ReviewJudgements.messages_file(dir))
    end

    test "a review whose end was already recorded is left alone", ctx do
      dispatch = review_dispatch(ctx)
      review_run_dir!(ctx, dispatch, [finding("one"), verdict()], %{"terminal_reported" => true})

      {_pid, _topic} = start_control(ctx, [])
      refute_receive {:test_loopctl, {:review_finding, _}}, 800
      refute_receive {:test_loopctl, {:session_ended, _}}, 100
    end
  end

  describe "a review run whose task dies" do
    test "is reported from what it left on disk: its judgements, then session_ended crashed",
         ctx do
      test = self()
      dispatch = review_dispatch(ctx)

      stalling = fn _config, _work, opts ->
        dir =
          review_run_dir!(
            ctx,
            dispatch,
            [finding("one")],
            %{"status" => "running"} |> Map.merge(owner!())
          )

        Keyword.fetch!(opts, :on_stage).({:started, %{run_id: Session.uuid4(), run_dir: dir}})
        send(test, {:stalled, dir})
        Process.sleep(:infinity)
      end

      capture_log(fn ->
        {pid, topic} = start_control(ctx, review_run: stalling)
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert %{"decision" => "accepted"} = next(:dispatch_reply)
        assert_receive {:stalled, dir}, 10_000
        :ok = wait_until(fn -> Control.info(pid).run_dirs[dispatch["dispatch_id"]] == dir end)
        [task] = Task.Supervisor.children(ctx.run_supervisor)
        Process.exit(task, :kill)

        assert %{"client_seq" => 0, "body" => "one"} = next(:review_finding)
        assert next(:session_ended)["reason"] == "crashed"
        :ok = wait_until(end_recorded(dir))
        assert {:ok, %{"status" => "crashed"}} = RunState.read(dir)
      end)
    end
  end

  describe "a review run whose task is killed" do
    test "leaves its scratch tree to the next reap, which removes it and its project directory",
         ctx do
      test = self()
      dispatch = review_dispatch(ctx)
      repo = Path.join(ctx.root, "repo")
      run_id = Session.uuid4()
      tree = Worktree.triage_tree_path(ctx.config.runs_dir, repo, run_id)
      project = Path.join(ctx.config.claude_projects_dir, "-scratch-" <> run_id)

      # Killed mid-session: its teardown, in the run's `after`, never runs.
      stalling = fn _config, _work, opts ->
        state =
          %{"status" => "running", "run_id" => run_id, "repo_path" => repo}
          |> Map.merge(owner!())

        dir = review_run_dir!(ctx, dispatch, [finding("one")], state)
        {:ok, sha} = Worktree.create_detached(repo, tree)
        ScratchRun.record_tree(dir, %{repo_path: repo, path: tree, base: sha}, "created")
        File.mkdir_p!(project)
        Keyword.fetch!(opts, :on_stage).({:started, %{run_id: run_id, run_dir: dir}})
        send(test, {:stalled, dir})
        Process.sleep(:infinity)
      end

      capture_log(fn ->
        {pid, topic} = start_control(ctx, review_run: stalling)
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert %{"decision" => "accepted"} = next(:dispatch_reply)
        assert_receive {:stalled, dir}, 10_000
        :ok = wait_until(fn -> Control.info(pid).run_dirs[dispatch["dispatch_id"]] == dir end)
        [task] = Task.Supervisor.children(ctx.run_supervisor)
        Process.exit(task, :kill)

        assert next(:session_ended)["reason"] == "crashed"
        :ok = wait_until(end_recorded(dir))

        assert {:ok, %{"status" => "crashed", "worktree" => %{"status" => "remove_failed"}}} =
                 RunState.read(dir)

        assert File.dir?(tree)

        # This BEAM still owns the run, and the run is over: the next reap collects its tree.
        Reaper.reap(ctx.config.runs_dir, 500, ctx.config.grant_dir,
          projects_dir: ctx.config.claude_projects_dir
        )

        refute File.dir?(tree)
        refute File.dir?(project)
        assert {:ok, %{"worktree" => %{"status" => "removed"}}} = RunState.read(dir)
      end)
    end
  end

  describe "a review run whose task dies with its session still running" do
    # Starts a Control, has it accept `dispatch` onto a run that records `session` as its live
    # session and a finding, and kills that run's task.
    defp kill_review_run!(ctx, dispatch, session) do
      test = self()

      stalling = fn _config, _work, opts ->
        tree_file = Path.join(ctx.root, "stderr.log.tree")

        File.write!(
          tree_file,
          "#{session} #{LoopctlRunner.TestSupport.utc_start_time(session)}\n"
        )

        state =
          %{"status" => "running", "session_id" => Session.uuid4(), "tree_file" => tree_file}
          |> Map.merge(owner!())

        dir = review_run_dir!(ctx, dispatch, [finding("one")], state)
        Keyword.fetch!(opts, :on_stage).({:started, %{run_id: Session.uuid4(), run_dir: dir}})
        send(test, {:stalled, dir})
        Process.sleep(:infinity)
      end

      {pid, topic} = start_control(ctx, review_run: stalling)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert %{"decision" => "accepted"} = next(:dispatch_reply)
      assert_receive {:stalled, dir}, 10_000
      :ok = wait_until(fn -> Control.info(pid).run_dirs[dispatch["dispatch_id"]] == dir end)
      assert os_pid_alive?(session)
      [task] = Task.Supervisor.children(ctx.run_supervisor)
      Process.exit(task, :kill)
      {pid, task}
    end

    # Control.info asked every 50ms until `ms` have passed, each answer timed.
    defp answers_throughout(pid, ms) do
      deadline = System.monotonic_time(:millisecond) + ms
      answer_until(pid, deadline)
    end

    defp answer_until(pid, deadline) do
      if System.monotonic_time(:millisecond) < deadline do
        {micros, info} = :timer.tc(fn -> Control.info(pid) end)
        assert micros < 300_000, "Control.info took #{div(micros, 1000)}ms"
        assert info.joined
        Process.sleep(50)
        answer_until(pid, deadline)
      end
    end

    test "has the session ended BEFORE what it stated is composed", ctx do
      dispatch = review_dispatch(ctx)
      session = live_session!(false)

      capture_log(fn ->
        {_pid, _task} = kill_review_run!(ctx, dispatch, session)

        # Composed and sent only once the session could state nothing more.
        assert %{"client_seq" => 0} = next(:review_finding)
        refute os_pid_alive?(session)
        assert next(:session_ended)["reason"] == "crashed"
      end)
    end

    test "a Control starting over a run whose owner died ends its session before composing too",
         ctx do
      dispatch = review_dispatch(ctx)
      session = live_session!(false)
      tree_file = Path.join(ctx.root, "stderr.log.tree")
      File.write!(tree_file, "#{session} #{LoopctlRunner.TestSupport.utc_start_time(session)}\n")

      # In flight, and no owner recorded: a run whose BEAM is gone, its session still up.
      review_run_dir!(ctx, dispatch, [finding("one")], %{
        "status" => "running",
        "session_id" => Session.uuid4(),
        "tree_file" => tree_file
      })

      capture_log(fn ->
        {_pid, _topic} = start_control(ctx, [])
        assert %{"client_seq" => 0} = next(:review_finding)
        refute os_pid_alive?(session)
        assert next(:session_ended)["reason"] == "crashed"
      end)
    end

    test "Control keeps answering while a session that ignores TERM is being ended", ctx do
      dispatch = review_dispatch(ctx)
      session = live_session!(true)

      capture_log(fn ->
        {pid, _task} = kill_review_run!(ctx, dispatch, session)

        # The grace is 2s and the session outlives its TERM for all of it; Control answers
        # throughout, because the ending is not done on its process.
        answers_throughout(pid, 1_500)

        assert os_pid_alive?(session)
        refute_received {:test_loopctl, {:review_finding, _}}

        # Composed once the KILL that follows the grace has ended it.
        assert %{"client_seq" => 0} = next(:review_finding)
        refute os_pid_alive?(session)
        assert next(:session_ended)["reason"] == "crashed"
      end)
    end

    test "a task ending the session that dies still has the review composed, and says so", ctx do
      dispatch = review_dispatch(ctx)
      session = live_session!(true)

      log =
        capture_log(fn ->
          {_pid, task} = kill_review_run!(ctx, dispatch, session)
          # The run's task is gone; what the supervisor holds now is the one ending the session.
          enders = fn -> Task.Supervisor.children(ctx.run_supervisor) -- [task] end
          :ok = wait_until(fn -> enders.() != [] end)
          [ender] = enders.()
          Process.exit(ender, :kill)

          assert %{"client_seq" => 0} = next(:review_finding)
          assert next(:session_ended)["reason"] == "crashed"
        end)

      assert log =~ "could not be ended before its end is reported"
    end
  end

  describe "a review under its dispatch's deadline_at (contract 1.19.0)" do
    # Room past what the kill grace and the skew margin need, in seconds.
    defp deadline_in(ctx, seconds),
      do:
        DateTime.utc_now()
        |> DateTime.add(ctx.config.kill_grace_s + Story.deadline_margin_s() + seconds, :second)

    defp iso(deadline), do: DateTime.to_iso8601(deadline)

    test "one that leaves no time to stop a session is refused other, never kind_not_supported",
         ctx do
      # The accept-path guard is the policy's, for every kind: a moment, and loopctl places the
      # review again. `kind_not_supported` would say this runner never reviews.
      {pid, topic} = start_control(ctx, [])
      dispatch = review_dispatch(ctx, %{"deadline_at" => iso(deadline_in(ctx, -1))})

      capture_log(fn ->
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

        assert %{"decision" => "refused", "reason" => "other", "detail" => detail} =
                 next(:dispatch_reply)

        assert detail =~ ~r/^deadline_passed: /
      end)

      assert Control.info(pid).pending_starts == []
      assert Control.info(pid).runs_in_flight == []
    end

    test "its session is stopped in time for it; what it stated goes, then session_ended crashed",
         ctx do
      TestLoopctl.put(:session_ended_replies, [:review])

      {_pid, topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "hang"}, {"FAKE_REVIEW_FINDINGS", "1"}])

      deadline = deadline_in(ctx, 4)
      dispatch = review_dispatch(ctx, %{"deadline_at" => iso(deadline)})
      id = dispatch["dispatch_id"]
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert %{"decision" => "accepted"} = next(:dispatch_reply)

      # The finding the session stated before the stop, then — no verdict was stated — the
      # session_ended: `crashed`, since loopctl's placement ran out rather than the review's own
      # wall clock (30 s), which would have been `wall_clock_exceeded`.
      assert %{"dispatch_id" => ^id, "client_seq" => 0} = next(:review_finding, 20_000)

      assert next(:session_ended) == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "reason" => "crashed"
             }

      assert DateTime.compare(DateTime.utc_now(), deadline) == :lt
      refute_receive {:test_loopctl, {:review_verdict, _}}, 300

      [{dir, state}] = RunState.all(ctx.config.runs_dir)
      assert state["status"] == "stopped_at_deadline"
      :ok = wait_until(end_recorded(dir))
    end

    test "one that passed before its session still frees the slot, and stays answered", ctx do
      # Past by the time the run begins, not when the dispatch was accepted: the run-start guard.
      # Unlike an implement run's, a review's end is still owed — the slot is freed by nothing but
      # its session_ended — so its dispatch is never forgotten as a sessionless one is.
      TestLoopctl.put(:session_ended_replies, [:review])
      test = self()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      review_run = fn config, work, opts ->
        send(test, :review_run_called)
        ReviewRun.execute(config, %{work | deadline_at: past}, opts)
      end

      {pid, topic} = running_control(ctx, [], review_run: review_run)
      dispatch = review_dispatch(ctx)
      id = dispatch["dispatch_id"]

      capture_log(fn ->
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert %{"decision" => "accepted"} = next(:dispatch_reply)
        assert_receive :review_run_called, 5_000

        assert next(:session_ended) == %{
                 "dispatch_id" => id,
                 "claim_epoch" => 3,
                 "reason" => "crashed"
               }

        :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 10_000)

        # A re-send — one past its deadline, so a dispatch decided afresh would be REFUSED — is
        # answered accepted, and starts nothing.
        TestLoopctl.Endpoint.broadcast(
          topic,
          "dispatch",
          Map.put(dispatch, "deadline_at", iso(past))
        )

        assert %{"dispatch_id" => ^id, "decision" => "accepted"} = next(:dispatch_reply)
        refute_receive :review_run_called, 500
      end)

      refute_receive {:test_loopctl, {:review_finding, _}}, 100
      [{dir, %{"status" => "deadline_passed"}}] = RunState.all(ctx.config.runs_dir)
      :ok = wait_until(end_recorded(dir))
    end

    test "a Control starting over one that passed before its session sends its end, and keeps it",
         ctx do
      # Its end was never recorded: a restart owes it, and — read with its kind — does not take it
      # for a sessionless run it may forget, so loopctl's re-send is answered, not decided afresh.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      dispatch = review_dispatch(ctx, %{"deadline_at" => iso(past)})
      id = dispatch["dispatch_id"]
      dir = review_run_dir!(ctx, dispatch, [], %{"status" => "deadline_passed"})

      capture_log(fn ->
        {_pid, topic} = start_control(ctx, [])
        assert %{"dispatch_id" => ^id, "reason" => "crashed"} = next(:session_ended)
        :ok = wait_until(end_recorded(dir))

        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert %{"dispatch_id" => ^id, "decision" => "accepted"} = next(:dispatch_reply)
      end)
    end

    test "a pending review re-sent with a later deadline_at is bounded by the later one", ctx do
      # Neither accept is recorded, so the start stays pending across the re-send.
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      TestLoopctl.put(:session_ended_replies, [:review])
      test = self()

      review_run = fn config, work, opts ->
        send(test, {:review_deadline, work.deadline_at})
        ReviewRun.execute(config, work, opts)
      end

      {pid, topic} =
        running_control(ctx, [{"FAKE_REVIEW_VERDICT", "fine"}], review_run: review_run)

      first = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      later = DateTime.add(first, 600, :second)
      dispatch = review_dispatch(ctx, %{"deadline_at" => iso(first)})
      id = dispatch["dispatch_id"]

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert %{"decision" => "accepted"} = next(:dispatch_reply)

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", %{dispatch | "deadline_at" => iso(later)})
      assert %{"decision" => "accepted"} = next(:dispatch_reply)

      assert [%{"dispatch_id" => ^id, "deadline_at" => on_disk}] =
               LoopctlRunner.PendingStarts.all(ctx.config.runs_dir)

      assert on_disk == iso(later)

      # This reply is recorded, and the review starts with the later deadline held in memory.
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert %{"decision" => "accepted"} = next(:dispatch_reply)
      assert_receive {:review_deadline, ^later}, 5_000
      assert next(:session_ended, 20_000)["reason"] == "completed"
      :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 10_000)
    end
  end

  defp rejoin(pid) do
    TestLoopctl.disconnect_runner()
    :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
  end
end
