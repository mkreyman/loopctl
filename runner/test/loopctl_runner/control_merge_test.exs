defmodule LoopctlRunner.ControlMergeTest do
  @moduledoc """
  US-48.17, Control's half of a merge instruction: loopctl's merge gate allowed a head and pushes
  `merge` (contract 1.29.0); the runner holding the claim merges exactly that head and reports
  `ci -> merged`, or the moved head, or the refusal.

  The run is on disk as `Run` leaves a finished pr-mode implement run, and the forge is injected
  (`:merge_forge`), so nothing here starts a session, reaches GitHub, or changes this BEAM's
  environment. `LoopctlRunner.MergeRunTest` covers what each forge answer means.
  """

  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    ClaimEnded,
    Contract,
    Control,
    ControlConfig,
    DispatchRun,
    PrStages,
    RunState,
    Session,
    TestLoopctl
  }

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  @head String.duplicate("ab", 20)
  @moved String.duplicate("cd", 20)
  @merge_sha String.duplicate("ef", 20)

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-merge")
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
          trace_poll_ms: 200,
          stage_retry_ms: 50,
          forge: fn _repo, _head, _base, _timeout -> {:ok, []} end,
          merge_opts: [retry_after_ms: 0]
        ],
        opts
      )

    {:ok, pid} = GenServer.start(Control, opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
    {pid, "runner:" <> TestLoopctl.get(:runner_id)}
  end

  defp dispatch(overrides \\ %{}) do
    story_id = Session.uuid4()

    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => story_id,
        "kind" => "implement",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "loop/story-#{System.unique_integer([:positive])}",
        "claim_epoch" => 3
      },
      overrides
    )
  end

  defp open_pr(dispatch, overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 3938,
        "state" => "OPEN",
        "headRefName" => dispatch["branch"],
        "headRefOid" => @head,
        "baseRefName" => dispatch["base_branch"],
        "isCrossRepository" => false,
        "mergeCommit" => nil
      },
      overrides
    )
  end

  defp merged_pr(dispatch),
    do: open_pr(dispatch, %{"state" => "MERGED", "mergeCommit" => %{"oid" => @merge_sha}})

  # A pr-mode implement run of `dispatch` that ended with its pull request open and green at
  # @head, its end reported, as `Run` and a Control leave one. `state` overrides its state.json.
  defp finished_run!(ctx, dispatch, state \\ %{}) do
    run_dir = Path.join(ctx.config.runs_dir, "run-#{dispatch["dispatch_id"]}")
    File.mkdir_p!(run_dir)

    green = [%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]

    observed =
      PrStages.observed(
        [open_pr(dispatch, %{"statusCheckRollup" => green})],
        dispatch["branch"],
        dispatch["base_branch"]
      )

    File.write!(
      Path.join(run_dir, "story.json"),
      JSON.encode!(%{
        "id" => DispatchRun.story_id(dispatch["story_id"]),
        "repo" => "fixture",
        "branch" => dispatch["branch"],
        "base" => dispatch["base_branch"]
      })
    )

    RunState.update(
      run_dir,
      dispatch
      |> DispatchRun.binding()
      |> Map.merge(%{
        "forge_repo" => dispatch["repo"],
        "status" => "succeeded",
        "reached" => "implementing",
        "observed_stages" => observed,
        "terminal_reported" => true
      })
      |> Map.merge(state)
    )

    run_dir
  end

  defp instruction(dispatch, overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => dispatch["claim_epoch"],
        "story_id" => dispatch["story_id"],
        "repo" => dispatch["repo"],
        "pr_number" => 3938,
        "head_sha" => @head,
        "merge_method" => "squash"
      },
      overrides
    )
  end

  # A forge whose reads answer `views` in order (the last repeats) and whose merge answers `merged`,
  # telling the test every call. `gate`, when true, holds the merge until the test sends
  # `:release` to the pid it is told about.
  defp merge_forge(views, merged \\ :ok, gate \\ false) do
    test = self()
    {:ok, reads} = Agent.start(fn -> views end)
    on_exit(fn -> if Process.alive?(reads), do: Agent.stop(reads) end)

    view = fn repo, number, _timeout ->
      send(test, {:forge_view, repo, number})

      Agent.get_and_update(reads, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end

    # `merged` is one answer for every merge, or a list answered in order (the last repeats).
    {:ok, answers} = Agent.start(fn -> List.wrap(merged) end)
    on_exit(fn -> if Process.alive?(answers), do: Agent.stop(answers) end)

    merge = fn repo, number, head, _body, _timeout ->
      send(test, {:forge_merge, repo, number, head, self()})
      if gate, do: receive(do: (:release -> :ok))

      Agent.get_and_update(answers, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end

    %{view: view, edit_body: fn _repo, _number, _body, _timeout -> :ok end, merge: merge}
  end

  defp next_stage(timeout \\ 5_000) do
    receive do
      {:test_loopctl, {:stage, payload}} -> payload
    after
      timeout -> flunk("no stage report within #{timeout}ms")
    end
  end

  # An instruction acted on by nothing: no read of the forge, no merge, no report.
  defp assert_dropped(log, why) do
    refute_receive {:test_loopctl, {:stage, _}}, 500
    refute_received {:forge_view, _, _}
    refute_received {:forge_merge, _, _, _, _}
    assert log =~ "merge instruction for pull request"
    assert log =~ why
  end

  describe "the instruction is validated against the contract" do
    test "RunnerMergeInstruction is vendored, and named as the `merge` event" do
      assert Contract.connection()["events"]["merge"] == "RunnerMergeInstruction"

      assert Contract.schema_def("RunnerMergeInstruction")["required"] |> Enum.sort() ==
               ~w(claim_epoch dispatch_id head_sha merge_method pr_number repo story_id)
    end

    test "each required field missing, a wrong merge method, and an extra key are refused", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)
      {_pid, topic} = running_control(ctx, merge_forge: merge_forge([{:ok, open_pr(dispatch)}]))

      malformed =
        for(
          field <- ~w(dispatch_id claim_epoch story_id repo pr_number head_sha merge_method),
          do: {field, Map.delete(instruction(dispatch), field)}
        ) ++
          [
            {"merge_method", instruction(dispatch, %{"merge_method" => "merge"})},
            {"extra", instruction(dispatch, %{"delete_branch" => true})},
            {"head_sha", instruction(dispatch, %{"head_sha" => "HEAD"})},
            {"pr_number", instruction(dispatch, %{"pr_number" => 0})}
          ]

      for {what, payload} <- malformed do
        log =
          capture_log(fn ->
            TestLoopctl.Endpoint.broadcast(topic, "merge", payload)
            refute_receive {:test_loopctl, {:stage, _}}, 300
          end)

        assert log =~ "it fails the contract", what
        refute_received {:forge_view, _, _}
        refute_received {:forge_merge, _, _, _, _}
      end
    end
  end

  describe "an instruction that does not match a dispatch this runner holds is dropped" do
    setup ctx do
      dispatch = dispatch()
      run_dir = finished_run!(ctx, dispatch)
      {:ok, dispatch: dispatch, run_dir: run_dir}
    end

    defp drop_log(ctx, payload) do
      capture_log(fn ->
        {_pid, topic} =
          running_control(ctx, merge_forge: merge_forge([{:ok, open_pr(ctx.dispatch)}]))

        TestLoopctl.Endpoint.broadcast(topic, "merge", payload)
        refute_receive {:test_loopctl, {:stage, _}}, 500
      end)
    end

    test "an unknown dispatch", ctx do
      log = drop_log(ctx, instruction(ctx.dispatch, %{"dispatch_id" => Session.uuid4()}))
      assert_dropped(log, "is on this runner")
    end

    test "another claim_epoch", ctx do
      log = drop_log(ctx, instruction(ctx.dispatch, %{"claim_epoch" => 4}))
      assert_dropped(log, "is held here at claim_epoch [3], not 4")
    end

    test "another story", ctx do
      log = drop_log(ctx, instruction(ctx.dispatch, %{"story_id" => Session.uuid4()}))
      assert_dropped(log, "not ")
      assert log =~ "is story #{inspect(ctx.dispatch["story_id"])}"
    end

    test "another repository", ctx do
      log = drop_log(ctx, instruction(ctx.dispatch, %{"repo" => "mkreyman/other"}))
      assert_dropped(log, "was for mkreyman/fixture, not mkreyman/other")
    end

    test "another pull request than the one the run observed", ctx do
      log = drop_log(ctx, instruction(ctx.dispatch, %{"pr_number" => 77}))
      assert_dropped(log, "observed another pull request than #77")
    end

    test "a claim loopctl ended", ctx do
      :ok =
        ClaimEnded.record(
          ctx.config.runs_dir,
          ctx.dispatch["dispatch_id"],
          3,
          "stage",
          "unknown_dispatch"
        )

      log = drop_log(ctx, instruction(ctx.dispatch))
      assert_dropped(log, "loopctl ended the claim")
    end

    test "a scratch run of the dispatch", ctx do
      RunState.update(ctx.run_dir, %{"kind" => "verify"})
      log = drop_log(ctx, instruction(ctx.dispatch))
      assert_dropped(log, "is a verify run, which merges nothing")
    end

    test "a run that recorded no branch and base", ctx do
      File.rm!(Path.join(ctx.run_dir, "story.json"))
      log = drop_log(ctx, instruction(ctx.dispatch))
      assert_dropped(log, "recorded no branch and base")
    end

    # No `forge_repo`: an earlier build's run, waiting at ci across the upgrade.
    defp without_forge_repo!(run_dir) do
      {:ok, state} = RunState.read(run_dir)
      File.write!(RunState.path(run_dir), JSON.encode!(Map.delete(state, "forge_repo")))
    end

    test "a run from before US-48.17: a repository this runner does not serve", ctx do
      without_forge_repo!(ctx.run_dir)
      log = drop_log(ctx, instruction(ctx.dispatch, %{"repo" => "someone/fixture"}))
      assert_dropped(log, "was for fixture, not someone/fixture")
    end

    test "a run from before US-48.17 is matched on the checkout's name within control.repos",
         ctx do
      without_forge_repo!(ctx.run_dir)

      {_pid, topic} =
        running_control(ctx, merge_forge: merge_forge([{:ok, merged_pr(ctx.dispatch)}]))

      TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(ctx.dispatch))
      id = ctx.dispatch["dispatch_id"]
      assert %{"dispatch_id" => ^id, "from" => "ci", "to" => "merged"} = next_stage()
    end

    test "a dispatch whose session is still running", ctx do
      # The dispatch is accepted and its run held open: what a session that has not finished
      # looks like to Control. A run on disk at start would make the dispatch a repeat that starts
      # nothing, so the state the run writes is put there once it has started.
      File.rm_rf!(ctx.run_dir)
      test = self()

      run = fn _config, _story, _opts ->
        send(test, :run_started)
        receive(do: (:never -> :ok))
      end

      log =
        capture_log(fn ->
          {_pid, topic} =
            running_control(ctx,
              run: run,
              merge_forge: merge_forge([{:ok, open_pr(ctx.dispatch)}])
            )

          dispatch =
            Map.merge(ctx.dispatch, %{
              "wall_clock_seconds" => 30,
              "max_turns" => 5,
              "story" => %{"id" => ctx.dispatch["story_id"], "title" => "Add a greeting"}
            })

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
          assert_receive :run_started, 5_000
          finished_run!(ctx, ctx.dispatch)

          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(ctx.dispatch))
          refute_receive {:test_loopctl, {:stage, _}}, 500
        end)

      assert_dropped(log, "session is still running")
    end

    test "a run whose end is still being reported", ctx do
      # Not settled yet: the restarted Control opens a stream for its end, and the merge waits for
      # loopctl's resend rather than queueing behind it.
      RunState.update(ctx.run_dir, %{"terminal_reported" => nil})
      TestLoopctl.put(:stage_replies, List.duplicate(:none, 10))

      log =
        capture_log(fn ->
          {_pid, topic} =
            running_control(ctx, merge_forge: merge_forge([{:ok, open_pr(ctx.dispatch)}]))

          assert %{"to" => "reviewing"} = next_stage()
          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(ctx.dispatch))
          refute_receive {:test_loopctl, {:stage, _}}, 500
        end)

      assert log =~ "still has stage reports going out"
      refute_received {:forge_merge, _, _, _, _}
    end
  end

  describe "a valid instruction" do
    test "TC-48.17.1: merges exactly the allowed head and reports ci -> merged with the merge sha",
         ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)

      forge = merge_forge([{:ok, open_pr(dispatch)}, {:ok, merged_pr(dispatch)}])
      {_pid, topic} = running_control(ctx, merge_forge: forge)

      TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))

      assert_receive {:forge_merge, "mkreyman/fixture", 3938, @head, _task}, 5_000

      assert next_stage() == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "from" => "ci",
               "to" => "merged",
               "edge" => "forward",
               "effects" => %{"merge_sha" => @merge_sha}
             }

      refute_receive {:test_loopctl, {:stage, _}}, 300
      refute_received {:forge_merge, _, _, _, _}
    end

    test "a pull request already merged at the allowed head is reported, not merged again", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)
      {_pid, topic} = running_control(ctx, merge_forge: merge_forge([{:ok, merged_pr(dispatch)}]))

      TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))

      assert %{"from" => "ci", "to" => "merged", "effects" => %{"merge_sha" => @merge_sha}} =
               next_stage()

      refute_received {:forge_merge, _, _, _, _}
    end

    test "a head that moved reports ci -> implementing over base_moved and merges nothing", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)
      moved = open_pr(dispatch, %{"headRefOid" => @moved})

      capture_log(fn ->
        {_pid, topic} = running_control(ctx, merge_forge: merge_forge([{:ok, moved}]))
        TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))

        assert %{
                 "from" => "ci",
                 "to" => "implementing",
                 "edge" => "base_moved",
                 "reason" => reason
               } =
                 next_stage()

        assert reason =~ "head is now #{@moved}, not #{@head}"
      end)

      refute_received {:forge_merge, _, _, _, _}
    end

    test "a refusal GitHub gives for another reason escalates with it", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)

      forge =
        merge_forge(
          [{:ok, open_pr(dispatch)}],
          {:refused, "gh exited 1: required reviews missing"}
        )

      capture_log(fn ->
        {_pid, topic} = running_control(ctx, merge_forge: forge)
        TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))

        assert %{
                 "from" => "ci",
                 "to" => "escalated",
                 "edge" => "session_escalated",
                 "reason" => reason
               } = next_stage()

        assert reason =~ "required reviews missing"
        # Escalated only after its one in-process retry was refused too.
        assert_received {:forge_merge, "mkreyman/fixture", 3938, @head, _task}
        assert_received {:forge_merge, "mkreyman/fixture", 3938, @head, _task}
        refute_received {:forge_merge, _, _, _, _}
      end)
    end

    test "a refusal that clears on the one retry is reported merged", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)

      forge =
        merge_forge(
          # First read, read after the refusal, the retry's read, the read after it merged.
          [
            {:ok, open_pr(dispatch)},
            {:ok, open_pr(dispatch)},
            {:ok, open_pr(dispatch)},
            {:ok, merged_pr(dispatch)}
          ],
          [
            {:refused, "gh exited 1: Base branch was modified. Review and try the merge again."},
            :ok
          ]
        )

      capture_log(fn ->
        {_pid, topic} = running_control(ctx, merge_forge: forge)
        TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))

        assert %{"from" => "ci", "to" => "merged", "effects" => %{"merge_sha" => @merge_sha}} =
                 next_stage()

        refute_receive {:test_loopctl, {:stage, _}}, 300
      end)
    end

    test "a forge it cannot read reports nothing", ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)

      log =
        capture_log(fn ->
          {_pid, topic} = running_control(ctx, merge_forge: merge_forge([{:error, "HTTP 502"}]))
          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))
          assert_receive {:forge_view, _, _}, 5_000
          refute_receive {:test_loopctl, {:stage, _}}, 500
        end)

      assert log =~ "nothing reported (unreachable)"
    end

    test "a duplicate while the merge runs is dropped; one after it reads first and merges nothing",
         ctx do
      dispatch = dispatch()
      finished_run!(ctx, dispatch)
      forge = merge_forge([{:ok, open_pr(dispatch)}, {:ok, merged_pr(dispatch)}], :ok, true)
      TestLoopctl.put(:stage_replies, [:ok, {:error, %{reason: "stale_stage", stage: "merged"}}])

      log =
        capture_log(fn ->
          {pid, topic} = running_control(ctx, merge_forge: forge)
          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))
          assert_receive {:forge_merge, _, 3938, @head, task}, 5_000
          # The read before the merge.
          assert_received {:forge_view, _, _}

          # loopctl resends after its answer window: the running merge answers it.
          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))
          refute_receive {:forge_view, _, _}, 300

          send(task, :release)
          assert %{"to" => "merged"} = next_stage()
          # The read after the merge.
          assert_received {:forge_view, _, _}

          # Once loopctl has recorded that report and the merge is over here:
          :ok =
            wait_until(fn ->
              info = Control.info(pid)
              info.stage_reports_pending == 0 and info.merges_in_flight == []
            end)

          # A resend after the merge finished reads the pull request, finds it merged, and
          # reports that merge again — loopctl already holds it, and nothing more goes.
          TestLoopctl.Endpoint.broadcast(topic, "merge", instruction(dispatch))
          assert_receive {:forge_view, _, _}, 5_000
          assert %{"to" => "merged", "effects" => %{"merge_sha" => @merge_sha}} = next_stage()
          refute_receive {:test_loopctl, {:stage, _}}, 300
          assert Control.info(pid).stage_reports_pending == 0
        end)

      assert log =~ "already running"
      # One merge, for three instructions.
      refute_received {:forge_merge, _, _, _, _}
    end
  end

  test "the runner adds no claim renewal: while a story waits at ci it only stays joined", ctx do
    # loopctl holds the claim itself while it sees this runner connected (US-48.17, AC-48.17.3,
    # `Progress.extend_ci_hold_lease/3`); the contract carries no runner-side renewal at all.
    refute Enum.any?(Map.keys(Contract.connection()["events"]), &(&1 =~ ~r/renew|lease|extend/))

    dispatch = dispatch()
    finished_run!(ctx, dispatch)
    {pid, _topic} = running_control(ctx, merge_forge: merge_forge([{:ok, open_pr(dispatch)}]))

    refute_receive {:test_loopctl, {:stage, _}}, 500
    refute_received {:test_loopctl, {:session_ended, _}}
    refute_received {:forge_view, _, _}
    assert Control.info(pid).joined
  end
end
