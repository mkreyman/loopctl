defmodule LoopctlRunner.ControlTriageTest do
  @moduledoc """
  The triage half of the accept path: what a `triage` dispatch is answered with, and what a triage
  run's verdict does on the wire.

  The first test drives a dispatch from the wire to a verdict carrying its lens verdicts. The rest
  drive the two other real sequences: a pending start this runner had already accepted and
  recorded on disk, and the outcome message a triage run sends back to whichever Control is alive.
  """

  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{
    Contract,
    Control,
    ControlConfig,
    PendingStarts,
    PendingVerdicts,
    Reaper,
    Runs,
    RunState,
    ScratchRun,
    Session,
    TestLoopctl,
    TriageDispatch,
    TriageRun,
    TriageVerdict,
    Worktree,
    WorktreeLock
  }

  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 90_000

  @verdict %{"outcome" => "escalate", "confidence" => "high", "missing_information" => ["why?"]}

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control-triage")
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

  defp start_control(ctx, opts) do
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

    {:ok, pid} =
      case opts[:name] do
        nil -> GenServer.start(Control, opts)
        name -> GenServer.start(Control, opts, name: name)
      end

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
    {pid, "runner:" <> TestLoopctl.get(:runner_id)}
  end

  # A joined client with the fake CLI on PATH for as long as the test runs.
  defp running_control(ctx, fake_vars, opts \\ []) do
    restore = fake_env!(ctx.fake, [{"FAKE_AGENTS", "busy"} | fake_vars])
    on_exit(fn -> restore.() end)
    start_control(ctx, opts)
  end

  defp triage_dispatch(overrides \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => Session.uuid4(),
        "kind" => "triage",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "loop/triage-#{System.unique_integer([:positive])}",
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

  defp story_dispatch(overrides \\ %{}) do
    story_id = Session.uuid4()

    Map.merge(
      %{
        "dispatch_id" => Session.uuid4(),
        "story_id" => story_id,
        "kind" => "implement",
        "repo" => "mkreyman/fixture",
        "base_branch" => "master",
        "branch" => "loop/story-#{System.unique_integer([:positive])}",
        "claim_epoch" => 3,
        "wall_clock_seconds" => 30,
        "max_turns" => 5,
        "story" => %{
          "id" => story_id,
          "title" => "Add a greeting",
          "description" => "Print hello on start.",
          "acceptance_criteria" => ["hello is printed"]
        }
      },
      overrides
    )
  end

  defp next_verdict(timeout \\ 10_000) do
    receive do
      {:test_loopctl, {:triage_verdict, payload}} -> payload
    after
      timeout -> flunk("no triage_verdict within #{timeout}ms")
    end
  end

  # The message a triage run sends its Control: the dispatch it answers, where the run keeps its
  # state, and what it concluded.
  defp outcome(pid, dispatch, outcome, run_dir \\ nil) do
    binding = Map.take(dispatch, ["dispatch_id", "claim_epoch"])
    send(pid, {:triage_outcome, binding, %{run_dir: run_dir}, outcome})
  end

  # A run directory as a run leaves it: a state naming the dispatch, so what is written beside it
  # is found by a Control that starts over it.
  defp run_dir!(ctx, dispatch, state \\ %{}) do
    dir = Path.join(ctx.config.runs_dir, "triage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    RunState.update(
      dir,
      %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => dispatch["claim_epoch"],
        "run_id" => Session.uuid4(),
        "kind" => "triage",
        "status" => "verdict"
      }
      |> Map.merge(state)
      # A state with no owner reads as an orphan; one with this BEAM's is what `Runs.in_flight/2`
      # counts and what nothing will reap.
      |> Map.merge(owner!())
    )

    dir
  end

  # A run that gets as far as `fun` and then stops where the test can kill it, standing in for a
  # task killed at a chosen point of `TriageRun.finish/5`.
  defp stalling_run(ctx, dispatch, fun) do
    fn _config, _triage, _repo, opts ->
      run_dir = run_dir!(ctx, dispatch, %{"status" => "running"})
      Keyword.fetch!(opts, :on_start).(%{run_id: Session.uuid4(), run_dir: run_dir})
      fun.(run_dir)
      # What `kill_the_run/3` waits for: killed before `fun` finished, a test would judge a run
      # that never recorded what it set out to.
      File.write!(Path.join(run_dir, ".stalled"), "")
      Process.sleep(:infinity)
    end
  end

  defp kill_the_run(ctx, pid, dispatch) do
    id = dispatch["dispatch_id"]
    assert :ok = wait_until(fn -> Control.info(pid).run_dirs[id] != nil end, 10_000)
    stalled = Path.join(Control.info(pid).run_dirs[id], ".stalled")
    assert :ok = wait_until(fn -> File.exists?(stalled) end, 10_000)
    [task] = Task.Supervisor.children(ctx.run_supervisor)
    Process.exit(task, :kill)
  end

  describe "a triage dispatch" do
    # End to end, from the wire: the declared kind is accepted, the session runs, and what it
    # stated reaches loopctl as a verdict WITH one lens verdict per lens beside it — the one shape
    # Gate A can evaluate rather than escalate.
    test "is accepted, runs, and its verdict reaches loopctl with its lens verdicts", ctx do
      story = %{
        "outcome" => "story",
        "confidence" => "high",
        "story" => %{"title" => "T", "description" => "D", "acceptance_criteria" => ["A"]}
      }

      lenses =
        for lens <- ~w(analyst architect engineer),
            do: %{"lens" => lens, "outcome" => "story", "confidence" => "high"}

      TestLoopctl.put(:triage_verdict_replies, [:ok])

      {pid, topic} =
        running_control(ctx, [
          {"FAKE_CLAUDE_MODE", "stream"},
          {"FAKE_VERDICT", Jason.encode!(Map.put(story, "lens_verdicts", lenses))}
        ])

      assert "triage" in Control.kinds()
      dispatch = triage_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert reply["dispatch_id"] == dispatch["dispatch_id"]
      assert reply["decision"] == "accepted"

      assert next_verdict() == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "verdict" => story,
               "lens_verdicts" => lenses
             }

      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)

      assert [{_dir, %{"kind" => "triage", "status" => "verdict"}}] =
               RunState.all(ctx.config.runs_dir)
    end
  end

  describe "a triage run this runner already accepted" do
    test "is resumed from its pending file, and its verdict reaches loopctl", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      TestLoopctl.put(:triage_verdict_replies, [:ok])

      {pid, _topic} =
        running_control(ctx, [
          {"FAKE_CLAUDE_MODE", "stream"},
          {"FAKE_VERDICT", Jason.encode!(@verdict)}
        ])

      # The accept is resent first: the run starts only once loopctl has recorded it.
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert reply["dispatch_id"] == dispatch["dispatch_id"]
      assert reply["decision"] == "accepted"

      assert next_verdict() == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "verdict" => @verdict
             }

      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)

      # Once, not twice: the task ending after its outcome was reported is not news, and a second
      # message carrying a different outcome for the same dispatch is refused already_recorded,
      # which is permanent.
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 800

      # The run is bound to the dispatch and recorded as a triage run, and it reports no stages:
      # the contract's stages move a story, and this dispatch has none.
      assert [{_dir, state}] = RunState.all(ctx.config.runs_dir)
      assert state["kind"] == "triage"
      assert state["dispatch_id"] == dispatch["dispatch_id"]
      assert state["status"] == "verdict"
      refute_receive {:test_loopctl, {:stage, _}}, 300
      assert PendingStarts.all(ctx.config.runs_dir) == []

      # Recorded by loopctl, so nothing is owed for it any more: the copy kept for a restart goes
      # with the acknowledgement.
      assert PendingVerdicts.all(ctx.config.runs_dir) == []

      # Its trace ships like any other run's: a triage run's state names the dispatch and the
      # claim epoch, which is what TraceShip selects on.
      run_id = state["run_id"]
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 10_000
      assert Enum.any?(events, &(&1["type"] == "triage.started"))
    end

    test "whose deadline_at passed is dropped: no accept resent, no run, nothing reported", ctx do
      passed = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      dispatch = triage_dispatch(%{"deadline_at" => passed})
      id = dispatch["dispatch_id"]
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      {pid, _topic} =
        running_control(ctx, [
          {"FAKE_CLAUDE_MODE", "stream"},
          {"FAKE_VERDICT", Jason.encode!(@verdict)}
        ])

      refute_receive {:test_loopctl, {:dispatch_reply, %{"dispatch_id" => ^id}}}, 1_000
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 300
      assert PendingStarts.all(ctx.config.runs_dir) == []
      assert Control.info(pid).runs_in_flight == []
      assert RunState.all(ctx.config.runs_dir) == []
      # The fake CLI never ran.
      refute File.exists?(Path.join(ctx.fake, "argv"))
    end

    test "that began past its deadline_at sends no verdict, not even an account of it", ctx do
      # Past by the time the run begins, though not at the accept: the run-start guard. The run
      # owes nothing, and its task ending must not report the missing verdict in its place.
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      triage_run = fn config, triage, repo, opts ->
        TriageRun.execute(
          config,
          triage,
          repo,
          Keyword.put(opts, :deadline_at, past)
        )
      end

      # Through a pending start: an accept this runner already gave.
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      {pid, topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_run: triage_run)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 10_000)

      refute_receive {:test_loopctl, {:triage_verdict, _}}, 1_000
      assert PendingVerdicts.all(ctx.config.runs_dir) == []

      assert [{_dir, %{"status" => "deadline_passed", "terminal_reported" => "skipped"}}] =
               RunState.all(ctx.config.runs_dir)

      # Handled, not merely unsent: an outcome with no message is no reason for Control to die.
      assert Process.alive?(pid)
      assert Control.info(pid).joined

      # And forgotten: loopctl's re-send is decided afresh and starts a run of its own, rather
      # than being answered from the run that ended.
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      :ok = wait_until(fn -> length(RunState.all(ctx.config.runs_dir)) == 2 end, 10_000)
    end

    test "whose verdict its Control died before delivering is sent by the next one", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      # The first push is never answered; the second Control's resend is a replay.
      TestLoopctl.put(:triage_verdict_replies, [:none, :replayed])

      {pid, _topic} =
        running_control(
          ctx,
          [{"FAKE_CLAUDE_MODE", "stream"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
          triage_verdict_retry_ms: 100
        )

      sent = next_verdict()
      assert sent["verdict"] == @verdict
      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 1 end, 5_000)

      # What is on disk is what was sent, not the materials to rebuild it: loopctl refuses a
      # different verdict for the same dispatch permanently.
      assert [{_run_dir, stored}] = PendingVerdicts.all(ctx.config.runs_dir)
      assert stored == sent

      # The Control dies with the verdict unacknowledged, and the run is long over.
      GenServer.stop(pid)
      {second, _topic} = start_control(ctx, triage_verdict_retry_ms: 100)

      assert next_verdict() == sent
      assert :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
      # It is delivered, not re-run: the run that produced it is not started again.
      assert Control.info(second).runs_in_flight == []
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
    end

    test "that finishes with no Control registered has its outcome sent by the next one", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      TestLoopctl.put(:triage_verdict_replies, [:ok])
      name = :"control_#{System.unique_integer([:positive])}"

      # A session that outlives the Control that started it, and a Control registered under a name
      # nothing will hold again: the run's outcome message has nowhere to go.
      {pid, _topic} =
        running_control(
          ctx,
          [{"FAKE_CLAUDE_MODE", "quiet_then_result"}, {"FAKE_VERDICT", Jason.encode!(@verdict)}],
          name: name
        )

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      id = dispatch["dispatch_id"]
      assert :ok = wait_until(fn -> Control.info(pid).run_dirs[id] != nil end, 10_000)

      GenServer.stop(pid)
      refute Process.whereis(name)

      # The run finishes anyway and records what it concluded, as the message that states it.
      assert :ok =
               wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) != [] end, 15_000)

      assert [{_run_dir, recorded}] = PendingVerdicts.all(ctx.config.runs_dir)

      assert recorded == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "verdict" => @verdict
             }

      # Nobody was ever told, and the answer still reaches loopctl: the next Control sends what
      # the run recorded, and sends it as recorded.
      {_second, _topic} = start_control(ctx, triage_verdict_retry_ms: 100)
      assert next_verdict() == recorded
      assert :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
    end

    test "a resent verdict whose dispatch has gone away is noted, not raised as an error", ctx do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)
      {:ok, recorded} = TriageDispatch.verdict_message(dispatch, {:verdict, @verdict})
      :ok = PendingVerdicts.write(run_dir, recorded)
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "unknown_dispatch"}}])

      log =
        capture_log(fn ->
          {_pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          next_verdict()
          assert :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
        end)

      # The expected end of a resend: the claim moved on while the message waited, and an operator
      # woken for it learns nothing.
      assert log =~ "loopctl no longer needs the resent triage verdict (unknown_dispatch)"
      refute log =~ "giving up on the triage verdict"
    end

    test "whose stored verdict is not a message this runner may send is kept, unsent", ctx do
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)
      # Neither verdict nor incomplete: loopctl refuses it invalid_payload, permanently, so
      # sending it would spend the run's one report on a refusal.
      :ok =
        PendingVerdicts.write(run_dir, %{
          "dispatch_id" => dispatch["dispatch_id"],
          "claim_epoch" => 3
        })

      log =
        capture_log(fn ->
          {_pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 1_500
        end)

      assert log =~ "is not a message this runner may send"
      # Kept: it is the only record of what that run concluded.
      assert [{^run_dir, _}] = PendingVerdicts.all(ctx.config.runs_dir)
    end

    test "whose task dies is still reported, as no_verdict_written", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      # An exit reason of no fixed size, which is what a linked process taking the task down
      # actually leaves: `inspect/2`'s :limit bounds container elements, not the length of a
      # binary inside one, so nothing before the payload's own cap cuts this.
      huge = {%RuntimeError{message: String.duplicate("claude exited: ", 60)}, []}

      log =
        capture_log(fn ->
          {_pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}],
              triage_run: fn _config, _triage, _repo, _opts -> exit(huge) end
            )

          payload = next_verdict()
          assert payload["dispatch_id"] == dispatch["dispatch_id"]
          assert payload["incomplete"] == "no_verdict_written"
          assert payload["detail"] =~ "the run's process died"
          refute Map.has_key?(payload, "verdict")

          # Cut to the contract's cap rather than refused for being over it: a detail one
          # codepoint too long is invalid_payload, which is permanent, so the run's only report
          # would be discarded over the least important field in it.
          assert String.length(payload["detail"]) == 300
          assert Contract.validate("RunnerTriageVerdictMessage", payload) == :ok
        end)

      assert log =~ "the triage run of dispatch #{dispatch["dispatch_id"]} the run's process died"
    end

    # `finish/5` records the outcome BEFORE the trace closes, the state is written or the task
    # returns, so this window is real: the run has stated its verdict and this process has seen
    # only a death.
    test "whose task is killed after recording its verdict sends THAT, not the death", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      {:ok, recorded} = TriageDispatch.verdict_message(dispatch, {:verdict, @verdict})

      run =
        stalling_run(ctx, dispatch, fn run_dir ->
          :ok = PendingVerdicts.write(run_dir, recorded)
        end)

      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_run: run)

      capture_log(fn ->
        kill_the_run(ctx, pid, dispatch)

        # A report over this would be a DIFFERENT verdict for the dispatch, which loopctl refuses
        # already_recorded, permanently: the real one could then never be delivered at all.
        assert next_verdict() == recorded
      end)
    end

    test "whose task is killed after the session stated a verdict sends the verdict it wrote",
         ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      # Written by the session and never read by the run, which is where a kill during the
      # session's own teardown leaves it.
      run =
        stalling_run(ctx, dispatch, fn run_dir ->
          File.write!(TriageVerdict.file(run_dir), Jason.encode!(@verdict))
        end)

      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_run: run)

      capture_log(fn ->
        kill_the_run(ctx, pid, dispatch)

        payload = next_verdict()
        assert payload["verdict"] == @verdict
        refute Map.has_key?(payload, "incomplete")
      end)
    end

    test "whose recorded outcome is not a message this runner may send falls back to the verdict",
         ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      run =
        stalling_run(ctx, dispatch, fn run_dir ->
          File.write!(TriageVerdict.file(run_dir), Jason.encode!(@verdict))
          # Readable JSON, and not a message: neither verdict nor incomplete. Pushed, loopctl
          # refuses it invalid_payload — permanent — and settling that refusal would delete the
          # file, taking the fallback to the real verdict with it.
          :ok =
            PendingVerdicts.write(run_dir, %{
              "dispatch_id" => dispatch["dispatch_id"],
              "claim_epoch" => 3
            })
        end)

      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_run: run)

      log =
        capture_log(fn ->
          kill_the_run(ctx, pid, dispatch)

          payload = next_verdict()
          assert payload["verdict"] == @verdict
          refute Map.has_key?(payload, "incomplete")
        end)

      assert log =~ "is not a message this runner may send"
    end

    test "that reports normally but could not write its own end is still closed", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      # `TriageRun.finish/5` is rescue-guarded: a run whose state could not be written reports its
      # outcome perfectly well and leaves `running` behind.
      run = fn _config, _triage, _repo, opts ->
        run_dir = run_dir!(ctx, dispatch, %{"status" => "running"})
        Keyword.fetch!(opts, :on_start).(%{run_id: Session.uuid4(), run_dir: run_dir})
        %{run_id: Session.uuid4(), run_dir: run_dir, session: nil, outcome: {:verdict, @verdict}}
      end

      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_run: run)

      payload = next_verdict()
      assert payload["verdict"] == @verdict

      assert [{run_dir, _}] = RunState.all(ctx.config.runs_dir)

      assert :ok =
               wait_until(
                 fn -> match?({:ok, %{"status" => "crashed"}}, RunState.read(run_dir)) end,
                 5_000
               )

      assert Runs.in_flight(ctx.config.runs_dir) == 0
      assert Control.info(pid).runs_in_flight == []
    end

    test "whose task is killed reports, closes its own state, and stops counting in flight",
         ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      # A session that stays up for a couple of seconds, so the task can be killed while the run
      # is genuinely under way — the case where only the run directory it announced can close it.
      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "quiet_then_result"}])

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      :ok = wait_until(fn -> RunState.all(ctx.config.runs_dir) != [] end, 10_000)
      assert [{run_dir, %{"status" => "running"} = state}] = RunState.all(ctx.config.runs_dir)
      assert state["kind"] == "triage"
      # The state the run announced is this BEAM's own, so nothing reaps it: in flight until it
      # is closed, and only whoever learned the directory can close it.
      assert Runs.in_flight(ctx.config.runs_dir) == 1
      # Waited on as a fact, not as a delay: the run announced its directory and Control has
      # recorded it, which is what makes closing the state possible once the task is gone.
      id = dispatch["dispatch_id"]
      assert :ok = wait_until(fn -> Control.info(pid).run_dirs[id] == run_dir end, 5_000)

      [task] = Task.Supervisor.children(ctx.run_supervisor)

      log =
        capture_log(fn ->
          Process.exit(task, :kill)

          payload = next_verdict()
          assert payload["dispatch_id"] == dispatch["dispatch_id"]
          assert payload["incomplete"] == "no_verdict_written"

          assert :ok =
                   wait_until(
                     fn -> match?({:ok, %{"status" => "crashed"}}, RunState.read(run_dir)) end,
                     5_000
                   )
        end)

      assert log =~ "the triage run of dispatch #{dispatch["dispatch_id"]} the run's process died"
      assert Runs.in_flight(ctx.config.runs_dir) == 0
      assert Control.info(pid).runs_in_flight == []
    end
  end

  describe "the verdict on the wire" do
    test "an incomplete outcome is sent with its reason and detail, never a verdict too", ctx do
      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
      dispatch = triage_dispatch()
      outcome(pid, dispatch, {:incomplete, "verdict_invalid", "missing confidence"})

      payload = next_verdict()
      assert payload["incomplete"] == "verdict_invalid"
      assert payload["detail"] == "missing confidence"
      refute Map.has_key?(payload, "verdict")
    end

    test "an ack says whether it recorded the verdict or replayed one, and the log says so",
         ctx do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)
      TestLoopctl.put(:triage_verdict_replies, [:replayed])

      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          outcome(pid, triage_dispatch(), {:verdict, @verdict})
          next_verdict()
          :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)
        end)

      assert log =~ "loopctl recorded the triage verdict at "
      assert log =~ "(replayed: true)"
    end

    test "a rate-limited verdict waits out the refill and is sent again, unchanged", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "rate_limited"}}, :ok])

      {pid, _topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

      outcome(pid, triage_dispatch(), {:verdict, @verdict})

      first = next_verdict()
      assert next_verdict() == first
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
      refute_receive {:test_loopctl, {:triage_verdict, _}}, 500
    end

    test "a permanent refusal is logged as an error, never resent, and not kept for a restart",
         ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "already_recorded"}}])
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          outcome(pid, dispatch, {:verdict, @verdict}, run_dir)
          next_verdict()
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
          assert Control.info(pid).triage_verdict_backlog == 0
        end)

      assert log =~
               "giving up on the triage verdict for dispatch #{dispatch["dispatch_id"]} " <>
                 "(already_recorded): nothing will change it"

      # Nothing will move this refusal, so a copy left on disk would be resent by every restart
      # from now on and refused again each time.
      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "stale_claim_epoch is resent once as the same bytes, and a second one gives it up",
         ctx do
      # 1.22.0 `permanent_error_conditions.stale_claim_epoch`: on a triage_verdict it is permanent
      # for THAT message only — "resend the verdict once, with the same bytes, before giving it up".
      stale = {:error, %{reason: "stale_claim_epoch"}}
      TestLoopctl.put(:triage_verdict_replies, [stale, stale])
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          outcome(pid, dispatch, {:verdict, @verdict}, run_dir)
          first = next_verdict()
          assert next_verdict() == first
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
          assert Control.info(pid).triage_verdict_backlog == 0
        end)

      assert log =~ "resending the same bytes once"

      assert log =~
               "giving up on the triage verdict for dispatch #{dispatch["dispatch_id"]} " <>
                 "(stale_claim_epoch): refused so again after its one resend"

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "that a verdict was resent is recorded beside it while the resend is in flight", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "stale_claim_epoch"}}, :none])
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)

      capture_log(fn ->
        {pid, _topic} =
          running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

        outcome(pid, dispatch, {:verdict, @verdict}, run_dir)
        first = next_verdict()
        assert next_verdict() == first
        assert PendingVerdicts.resent?(run_dir)
        GenServer.stop(pid)
      end)
    end

    test "a verdict with no run directory remembers its one resend in memory", ctx do
      # Nothing on disk to keep the mark beside, so this process's own memory is what bounds it.
      stale = {:error, %{reason: "stale_claim_epoch"}}
      TestLoopctl.put(:triage_verdict_replies, [stale, stale])

      capture_log(fn ->
        {pid, _topic} =
          running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

        outcome(pid, triage_dispatch(), {:verdict, @verdict})
        first = next_verdict()
        assert next_verdict() == first
        refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
      end)
    end

    test "a stale_claim_epoch resend that lands is the end of it", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "stale_claim_epoch"}}, :ok])

      capture_log(fn ->
        {pid, _topic} =
          running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

        outcome(pid, triage_dispatch(), {:verdict, @verdict})
        first = next_verdict()
        assert next_verdict() == first
        refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
        :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 0 end, 5_000)
      end)
    end

    test "1.22.0's per-message codes give the verdict up at once, never resent", ctx do
      for reason <- ~w(claim_epoch_mismatch wrong_dispatch_kind) do
        TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: reason}}])

        log =
          capture_log(fn ->
            {pid, _topic} =
              running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

            outcome(pid, triage_dispatch(), {:verdict, @verdict})
            next_verdict()
            refute_receive {:test_loopctl, {:triage_verdict, _}}, 600
            GenServer.stop(pid)
          end)

        assert log =~ "(#{reason}): nothing will change it", reason
      end
    end

    test "a triage session whose claim a trace refusal ended is stopped, and sends no verdict",
         ctx do
      # 1.22.0 `claim_ending_errors.trace`: the claim is over, so the session is stopped and its
      # verdict — work of that dispatch — is never sent; it is settled without a round trip.
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "unknown_dispatch"}}])

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "hang"}], session_stop_retry_ms: 100)

          assert_receive {:test_loopctl, {:trace, _}}, 10_000
          :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 20_000)
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
          assert Control.info(pid).triage_verdicts_pending == 0
        end)

      assert log =~
               "the triage verdict of dispatch #{dispatch["dispatch_id"]} is not sent: " <>
                 "loopctl ended the claim it ran under"

      assert PendingVerdicts.all(ctx.config.runs_dir) == []
    end

    test "a claim-ending refusal of a repeated accept stops the stream-less triage session",
         ctx do
      # A triage run has no stage stream. Delivered again at the same epoch, its dispatch is
      # answered `accepted` again, and that answer refused `unknown_dispatch` — claim-ending for a
      # dispatch_reply — ends the claim the running session holds: it is stopped, and its verdict
      # is never sent.
      dispatch = triage_dispatch()
      id = dispatch["dispatch_id"]
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      TestLoopctl.put(:dispatch_reply_replies, [:ok, {:error, %{reason: "unknown_dispatch"}}])

      log =
        capture_log(fn ->
          {pid, topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "hang"}], session_stop_retry_ms: 100)

          session_running? = fn ->
            Enum.any?(RunState.all(ctx.config.runs_dir), fn {_dir, state} ->
              state["dispatch_id"] == id and is_integer(state["pgid"])
            end)
          end

          :ok = wait_until(session_running?, 15_000)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 20_000)
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
        end)

      assert log =~
               "loopctl refused dispatch_reply (unknown_dispatch) for dispatch #{id} at " <>
                 "claim_epoch 3, which ends that claim: the session of"

      assert log =~ "the triage verdict of dispatch #{id} is not sent"
    end

    test "a Control starting over stops the triage session whose claim was recorded over", ctx do
      # The Control that learnt of the claim's end is gone; the triage run it started is not, and
      # has no stage stream for anything to open. The next Control reads the claims recorded over
      # and stops the session of every run of them still in flight, whatever its kind.
      dispatch = triage_dispatch()
      id = dispatch["dispatch_id"]
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      session_running? = fn ->
        Enum.any?(RunState.all(ctx.config.runs_dir), fn {_dir, state} ->
          state["dispatch_id"] == id and is_integer(state["pgid"])
        end)
      end

      log =
        capture_log(fn ->
          {first, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "hang"}], session_stop_retry_ms: 100)

          :ok = wait_until(session_running?, 15_000)
          GenServer.stop(first)
          :ok = LoopctlRunner.ClaimEnded.record(ctx.config.runs_dir, id, 3, "trace", "x")
          # A claim that ended a week and more ago: the starting Control prunes it.
          stale = Session.uuid4()
          :ok = LoopctlRunner.ClaimEnded.record(ctx.config.runs_dir, stale, 1, "trace", "x")
          stale_marker = Path.join([ctx.config.runs_dir, ".claims", "#{stale}-1"])
          File.touch!(stale_marker, System.os_time(:second) - 8 * 24 * 3600)

          {_second, _topic} = start_control(ctx, session_stop_retry_ms: 100)

          :ok =
            wait_until(
              fn -> Task.Supervisor.children(ctx.run_supervisor) == [] end,
              15_000
            )

          refute File.exists?(stale_marker)
          assert LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, id, 3)

          refute_receive {:test_loopctl, {:triage_verdict, _}}, 500
        end)

      assert log =~
               "dispatch #{id}'s claim 3 was recorded over, and a run of it is still in flight"
    end

    test "failing to record that a verdict was resent is said, and the resend still goes", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "stale_claim_epoch"}}, :ok])
      gone = Path.join(ctx.root, "no-such-run-dir")

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          outcome(pid, triage_dispatch(), {:verdict, @verdict}, gone)
          first = next_verdict()
          assert next_verdict() == first
        end)

      assert log =~ "could not record beside the triage verdict that it was resent"
    end

    test "a restart sends no pending verdict whose claim was recorded ended", ctx do
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)
      {:ok, recorded} = TriageDispatch.verdict_message(dispatch, {:verdict, @verdict})
      :ok = PendingVerdicts.write(run_dir, recorded)

      :ok =
        LoopctlRunner.ClaimEnded.record(
          ctx.config.runs_dir,
          dispatch["dispatch_id"],
          3,
          "trace",
          "x"
        )

      capture_log(fn ->
        {_pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
        assert :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
        refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
      end)
    end

    test "a verdict already resent once before a restart is given up on the next stale_claim_epoch",
         ctx do
      dispatch = triage_dispatch()
      run_dir = run_dir!(ctx, dispatch)
      {:ok, recorded} = TriageDispatch.verdict_message(dispatch, {:verdict, @verdict})
      :ok = PendingVerdicts.write(run_dir, recorded)
      :ok = PendingVerdicts.mark_resent(run_dir)
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      log =
        capture_log(fn ->
          {_pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          assert next_verdict() == recorded
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
          assert :ok = wait_until(fn -> PendingVerdicts.all(ctx.config.runs_dir) == [] end, 5_000)
        end)

      assert log =~ "refused so again after its one resend"
      refute PendingVerdicts.resent?(run_dir)
    end

    test "a refusal this build does not know is given up on, not guessed at", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "reason_from_the_future"}}])

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          outcome(pid, triage_dispatch(), {:verdict, @verdict})
          next_verdict()
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
        end)

      assert log =~ "does not handle that refusal"
    end

    test "internal_error is retried to the terminal ceiling and then given up", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:triage_verdict_replies, [internal, internal, internal])
      dispatch = triage_dispatch()

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}],
              triage_verdict_retry_ms: 50,
              terminal_internal_error_attempts: 2
            )

          outcome(pid, dispatch, {:verdict, @verdict})
          next_verdict()
          next_verdict()
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 500
        end)

      assert log =~ "giving up on the triage verdict for dispatch #{dispatch["dispatch_id"]}"
      assert log =~ "(internal_error): 2 attempts"
    end

    # `dispatch_not_accepted` is the one refusal whose permanence has a condition, and the
    # condition is evidence only the runner holds: an accept of its own still unacknowledged.
    test "dispatch_not_accepted is resent while this runner's accept is still in flight", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [:none])

      TestLoopctl.put(:triage_verdict_replies, [
        {:error, %{reason: "dispatch_not_accepted"}},
        :ok
      ])

      {pid, topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

      # A real accept this runner pushed and loopctl never answered.
      accepted = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", accepted)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      :ok = wait_until(fn -> Control.info(pid).dispatch_replies_pending == 1 end, 3_000)

      outcome(pid, accepted, {:verdict, @verdict})
      first = next_verdict()
      assert next_verdict() == first
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
    end

    test "dispatch_not_accepted is given up when no accept of ours is outstanding", ctx do
      TestLoopctl.put(:triage_verdict_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      dispatch = triage_dispatch()

      log =
        capture_log(fn ->
          {pid, _topic} =
            running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

          outcome(pid, dispatch, {:verdict, @verdict})
          next_verdict()
          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
        end)

      assert log =~
               "giving up on the triage verdict for dispatch #{dispatch["dispatch_id"]} " <>
                 "(dispatch_not_accepted): no accept of it is outstanding"
    end

    test "a verdict loopctl had not recorded when the channel closed is resent after the rejoin",
         ctx do
      TestLoopctl.put(:triage_verdict_replies, [:none, :ok])

      {pid, _topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], triage_verdict_retry_ms: 100)

      outcome(pid, triage_dispatch(), {:verdict, @verdict})
      first = next_verdict()
      :ok = wait_until(fn -> Control.info(pid).triage_verdicts_pending == 1 end, 3_000)

      send(TestLoopctl.get(:channel_pid), :close_channel)
      :ok = wait_until(fn -> Control.info(pid).joined end, 8_000)

      assert next_verdict() == first
      :ok = wait_until(fn -> Control.info(pid).triage_verdict_backlog == 0 end, 5_000)
    end

    # An outcome that will not make a message is still a dispatch loopctl is waiting on, so what
    # matters is that SOMETHING it can record goes out.
    test "an outcome that cannot be made into a message is reported as one that can", ctx do
      dispatch = triage_dispatch()

      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          outcome(pid, dispatch, {:incomplete, "ran_out_of_ideas", "not a published reason"})

          payload = next_verdict()
          assert payload["dispatch_id"] == dispatch["dispatch_id"]
          assert payload["incomplete"] == "no_verdict_written"
          # What was wrong stays in the log: the errors can quote a verdict a session composed
          # after reading the reporter's own words.
          assert payload["detail"] =~ "see the runner's log"
          refute payload["detail"] =~ "ran_out_of_ideas"
        end)

      assert log =~ "is not a message this runner may send"
      assert log =~ "reporting no_verdict_written instead"
    end

    test "a binding no message can be addressed to is the one case nothing is sent for", ctx do
      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          # No dispatch_id: loopctl could not match a reply to anything, and this runner does not
          # invent one to have something to send.
          send(
            pid,
            {:triage_outcome, %{"claim_epoch" => 3}, %{run_dir: nil}, {:verdict, @verdict}}
          )

          refute_receive {:test_loopctl, {:triage_verdict, _}}, 800
        end)

      assert log =~ "nothing can be sent for dispatch"
    end

    test "a verdict this runner's own validation refuses is reported as verdict_invalid", ctx do
      dispatch = triage_dispatch()

      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          # A verdict the contract refuses: the session wrote one, and it is not one.
          outcome(pid, dispatch, {:verdict, %{"outcome" => "story"}})

          payload = next_verdict()
          assert payload["incomplete"] == "verdict_invalid"
          refute Map.has_key?(payload, "verdict")
        end)

      assert log =~ "reporting verdict_invalid instead"
    end
  end

  describe "what the log says" do
    test "an outcome that reached no Control names the dispatch and what the run concluded",
         ctx do
      _ = ctx
      name = :"no_control_#{System.unique_integer([:positive])}"

      message =
        {:triage_outcome, %{"dispatch_id" => "d1"}, %{run_dir: "/tmp/none"}, {:verdict, @verdict}}

      log =
        capture_log(fn ->
          assert Control.notify_control(name, message, wait_ms: 50, poll_ms: 10) == :ok
        end)

      assert log =~ "the triage outcome of dispatch d1 (a verdict (escalate, confidence high))"
      refute log =~ "unrecognised message"
    end

    # `rebuild_work/2` does not re-check the declaration, so this refusal can speak for a kind the
    # runner never declared: the wording has to be true of a pending file as well as of the wire.
    test "a pending dispatch of a kind with no accept path is dropped, not started", ctx do
      dispatch = triage_dispatch(%{"kind" => "audit"})
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)

      log =
        capture_log(fn ->
          {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])
          refute_receive {:test_loopctl, {:dispatch_reply, _}}, 800
          assert Control.info(pid).pending_starts == []
        end)

      assert log =~
               "pending dispatch #{dispatch["dispatch_id"]} no longer makes runnable work " <>
                 "(other: this runner has no accept path for a dispatch of kind audit)"

      refute log =~ "declares audit"
      assert PendingStarts.all(ctx.config.runs_dir) == []
    end
  end

  describe "a finished triage run a restart finds" do
    test "gets no terminal stage report: its report was the verdict", ctx do
      dispatch = triage_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "triage-run")
      File.mkdir_p!(run_dir)

      RunState.update(run_dir, %{
        "dispatch_id" => dispatch["dispatch_id"],
        "claim_epoch" => 3,
        "story_id" => dispatch["story_id"],
        "run_id" => Session.uuid4(),
        "kind" => "triage",
        "status" => "verdict"
      })

      {pid, _topic} = running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}])

      refute_receive {:test_loopctl, {:stage, _}}, 1_000
      assert Control.info(pid).stage_reports_pending == 0
    end
  end

  describe "a triage run whose task is killed holding a tree" do
    # A run that cuts `tree` and records it as `TriageRun` does, taking the reused tree's lock when
    # `tree` is that one, then stalls mid-session: its teardown, in the run's `after`, never runs.
    defp stalling_tree_run(ctx, dispatch, run_id, tree) do
      test = self()
      repo = Path.join(ctx.root, "repo")

      fn _config, _triage, _repo, opts ->
        run_dir = run_dir!(ctx, dispatch, %{"status" => "running", "run_id" => run_id})
        Keyword.fetch!(opts, :on_start).(%{run_id: run_id, run_dir: run_dir})

        shared? = tree == Worktree.triage_tree_path(ctx.config.runs_dir, repo)
        if shared?, do: :ok = WorktreeLock.acquire(ctx.config.runs_dir, tree, run_id, owner!())

        {:ok, sha} = Worktree.create_detached(repo, tree)

        ScratchRun.record_tree(
          run_dir,
          %{repo_path: repo, path: tree, base: sha, shared?: shared?},
          "created"
        )

        File.write!(Path.join(run_dir, ".stalled"), "")
        send(test, {:stalled, run_dir})
        Process.sleep(:infinity)
      end
    end

    defp kill_mid_session(ctx, dispatch, run, opts \\ []) do
      {pid, _topic} =
        running_control(ctx, [{"FAKE_CLAUDE_MODE", "stream"}], [triage_run: run] ++ opts)

      {run_dir, _log} =
        with_log(fn ->
          assert_receive {:stalled, run_dir}, 10_000
          kill_the_run(ctx, pid, dispatch)

          # Stated after the tree is given back, in the same pass: the tree's fate is settled here.
          assert next_verdict()["incomplete"] == "no_verdict_written"
          run_dir
        end)

      run_dir
    end

    defp reap!(ctx) do
      Reaper.reap(ctx.config.runs_dir, 500, ctx.config.grant_dir,
        projects_dir: ctx.config.claude_projects_dir
      )
    end

    test "leaves its OWN tree to the next reap, which removes it", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      run_id = Session.uuid4()
      own = Worktree.triage_tree_path(ctx.config.runs_dir, Path.join(ctx.root, "repo"), run_id)

      run_dir = kill_mid_session(ctx, dispatch, stalling_tree_run(ctx, dispatch, run_id, own))

      assert {:ok, %{"status" => "crashed", "worktree" => %{"status" => "remove_failed"}}} =
               RunState.read(run_dir)

      assert File.dir?(own)
      reap!(ctx)
      refute File.dir?(own)
    end

    test "frees the REUSED tree once the dead run's session is gone, and never gives it to the reaper",
         ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      run_id = Session.uuid4()
      shared = Worktree.triage_tree_path(ctx.config.runs_dir, Path.join(ctx.root, "repo"))

      run_dir = kill_mid_session(ctx, dispatch, stalling_tree_run(ctx, dispatch, run_id, shared))

      # Free: the dead run's session is gone, so the next triage takes the reused tree.
      assert WorktreeLock.live_holder(ctx.config.runs_dir, shared) == nil

      # Not marked: the reaper would remove a tree meant for reuse.
      assert {:ok, %{"status" => "crashed", "worktree" => %{"status" => "created"}}} =
               RunState.read(run_dir)

      reap!(ctx)
      assert File.dir?(shared)
    end

    test "keeps the dead run's hold while its session survived its end", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      run_id = Session.uuid4()
      shared = Worktree.triage_tree_path(ctx.config.runs_dir, Path.join(ctx.root, "repo"))
      survived = fn _state, _grace_ms -> {:survived, "{:error, :survived}"} end

      kill_mid_session(ctx, dispatch, stalling_tree_run(ctx, dispatch, run_id, shared),
        end_session: survived
      )

      assert WorktreeLock.live_holder(ctx.config.runs_dir, shared) == run_id
    end

    test "frees a hold the dead run took before its state recorded any tree", ctx do
      dispatch = triage_dispatch()
      :ok = PendingStarts.write(ctx.config.runs_dir, dispatch)
      repo = Path.join(ctx.root, "repo")
      shared = Worktree.triage_tree_path(ctx.config.runs_dir, repo)
      run_id = Session.uuid4()
      test = self()

      run = fn _config, _triage, _repo, opts ->
        run_dir = run_dir!(ctx, dispatch, %{"status" => "running", "run_id" => run_id})
        Keyword.fetch!(opts, :on_start).(%{run_id: run_id, run_dir: run_dir})
        :ok = WorktreeLock.acquire(ctx.config.runs_dir, shared, run_id, owner!())
        File.write!(Path.join(run_dir, ".stalled"), "")
        send(test, {:stalled, run_dir})
        Process.sleep(:infinity)
      end

      kill_mid_session(ctx, dispatch, run)
      assert WorktreeLock.live_holder(ctx.config.runs_dir, shared) == nil
    end
  end
end
