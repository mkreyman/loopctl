defmodule LoopctlRunner.ControlTest do
  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Contract, Control, ControlConfig, TestLoopctl}
  import ExUnit.CaptureLog
  import LoopctlRunner.TestSupport

  @moduletag timeout: 60_000

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("control")
    token_file = Path.join(root, "token")
    File.write!(token_file, TestLoopctl.get(:token) <> "\n")
    File.chmod!(token_file, 0o600)

    control = %ControlConfig{
      url: "ws://127.0.0.1:#{port}/runner/socket/websocket",
      runner_id: TestLoopctl.get(:runner_id),
      machine: "testbox",
      token_file: token_file,
      repos: ["mkreyman/home_care_billing"],
      max_sessions: 2,
      status_interval_s: 1
    }

    config = %{config!(root) | control: control}
    {:ok, config: config, token_file: token_file, root: root}
  end

  defp start_control(config, opts \\ []) do
    test = self()
    # Unlinked, and with the fatal hook reporting to the test instead of stopping the VM.
    # A forge with no pull requests unless a test passes its own: no test reaches GitHub.
    opts =
      Keyword.merge(
        [
          config: config,
          on_fatal: &send(test, {:fatal, &1}),
          forge: fn _repo, _head, _base, _timeout -> {:ok, []} end
        ],
        opts
      )

    {:ok, pid} =
      case opts[:name] do
        nil -> GenServer.start(Control, opts)
        name -> GenServer.start(Control, opts, name: name)
      end

    ref = Process.monitor(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, ref}
  end

  test "connects with the token in a header only, joins its own topic, and reports status", ctx do
    {pid, _ref} = start_control(ctx.config)

    assert_receive {:test_loopctl, {:connect, params}}, 5_000
    # The credential never travels in the URL: loopctl refuses a ?token=.
    refute Map.has_key?(params, "token")
    assert params["vsn"] == "2.0.0"

    runner_id = TestLoopctl.get(:runner_id)
    assert_receive {:test_loopctl, {:join, ^runner_id, join}}, 5_000
    assert Contract.validate("RunnerJoin", join) == :ok
    assert join["machine"] == "testbox"
    # 1.30.0 or later is what loopctl requires before it sends `spec_tune` (US-48.13).
    assert join["contract_version"] == "1.32.0"
    # Declared on EVERY join, from the same list the kind check reads.
    assert join["kinds"] == LoopctlRunner.Control.kinds()
    assert join["kinds"] == ["implement", "triage", "reply_draft", "verify", "spec_tune"]
    # Non-empty ON THE WIRE, which is where it decides anything: loopctl reads an empty array as
    # no declaration at all and falls back to its permanent ledger.
    refute join["kinds"] == []
    assert join["repos"] == ["mkreyman/home_care_billing"]
    # The SAME set DispatchPolicy enforces (contract 1.14.0): an undeclared prefix makes loopctl
    # derive branches this machine refuses.
    assert join["branch_prefixes"] == ctx.config.branch_prefixes
    # `specs` (AC-48.8.1) goes exactly when the vendored RunnerJoin names it: absent under 1.24.0,
    # the registry's entries for the declared kinds once 1.25.0 is vendored.
    joined_specs = Map.take(join, ["specs"])

    if Map.has_key?(Contract.schema_def("RunnerJoin")["properties"], "specs") do
      assert joined_specs == %{"specs" => LoopctlRunner.Templates.specs(Control.kinds())}
    else
      assert joined_specs == %{}
    end

    assert %{"sampled_at" => _, "free_disk_mb" => _} = join["sample"]

    assert_receive {:test_loopctl, {:status, status}}, 5_000
    assert Contract.validate("RunnerStatus", status) == :ok
    assert %{joined: true, topic: "runner:" <> ^runner_id} = Control.info(pid)
  end

  test "a refusal retrying cannot fix stops the client once, without rejoining", ctx do
    TestLoopctl.script_joins([{:error, %{reason: "machine_mismatch", declared: "testbox"}}])
    {pid, ref} = start_control(ctx.config)

    assert_receive {:fatal, {:join_refused, "machine_mismatch", _}}, 10_000

    assert_receive {:DOWN, ^ref, :process, ^pid,
                    {:shutdown, {:join_refused, "machine_mismatch", _}}}

    assert_receive {:test_loopctl, {:join, _, _}}
    refute_receive {:test_loopctl, {:join, _, _}}, 3_000
  end

  describe "loopctl announcing a disconnect (contract 1.2)" do
    test "a revoked runner stops instead of reconnecting", ctx do
      {pid, ref} = start_control(ctx.config)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      topic = "runner:" <> TestLoopctl.get(:runner_id)
      TestLoopctl.Endpoint.broadcast(topic, "disconnecting", %{"reason" => "runner_revoked"})

      assert_receive {:fatal, {:disconnecting, "runner_revoked"}}, 3_000

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:shutdown, {:disconnecting, "runner_revoked"}}},
                     2_000
    end

    test "a server shutdown is named on the close and the runner reconnects", ctx do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          topic = "runner:" <> TestLoopctl.get(:runner_id)
          TestLoopctl.Endpoint.broadcast(topic, "disconnecting", %{"reason" => "server_shutdown"})
          Process.sleep(100)
          TestLoopctl.disconnect_runner()

          :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
          assert Control.info(pid).last_disconnect =~ "(loopctl announced server_shutdown)"
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          refute_received {:fatal, _}
        end)

      assert log =~ "loopctl is disconnecting this runner (server_shutdown); it will reconnect"
    end

    test "an announcement is not carried onto a later, unrelated disconnect", ctx do
      {pid, _ref} = start_control(ctx.config)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      topic = "runner:" <> TestLoopctl.get(:runner_id)

      TestLoopctl.Endpoint.broadcast(topic, "disconnecting", %{"reason" => "server_shutdown"})
      Process.sleep(100)
      TestLoopctl.disconnect_runner()
      :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      # The announced shutdown and its close are over; the next drop is not announced.
      TestLoopctl.disconnect_runner()
      :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
      refute Control.info(pid).last_disconnect =~ "announced"
    end

    test "an announcement whose close never came is cleared by the next join", ctx do
      {pid, _ref} = start_control(ctx.config)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      topic = "runner:" <> TestLoopctl.get(:runner_id)

      TestLoopctl.Endpoint.broadcast(topic, "disconnecting", %{"reason" => "server_shutdown"})
      Process.sleep(100)
      # Only the channel closes, and the rejoin on the same socket succeeds.
      channel = TestLoopctl.get(:channel_pid)
      send(channel, :close_channel)
      :ok = wait_until(fn -> TestLoopctl.get(:channel_pid) != channel end, 8_000)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      TestLoopctl.disconnect_runner()
      :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
      refute Control.info(pid).last_disconnect =~ "announced"
    end

    test "a channel loopctl closes on its own is rejoined, not left for dead", ctx do
      {pid, _ref} = start_control(ctx.config)
      assert_receive {:test_loopctl, {:join, _, _}}, 5_000
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      send(TestLoopctl.get(:channel_pid), :close_channel)

      assert_receive {:test_loopctl, {:join, _, _}}, 8_000
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      assert Control.info(pid).last_disconnect =~ "closed_by_loopctl"
      assert Process.alive?(pid)
    end

    test "a join refused as no longer authorized stops the runner", ctx do
      TestLoopctl.script_joins([:not_authorized_disconnecting])
      {pid, ref} = start_control(ctx.config)

      assert_receive {:fatal, {:join_refused, "not_authorized", _}}, 5_000

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:shutdown, {:join_refused, "not_authorized", _}}},
                     2_000
    end
  end

  test "a rate-limited join is retried after a backoff", ctx do
    TestLoopctl.script_joins([
      {:error, %{reason: "rate_limited", max_joins: 30, window_ms: 60_000}}
    ])

    {pid, _ref} = start_control(ctx.config)

    assert_receive {:test_loopctl, {:join, _, _}}, 5_000
    assert_receive {:test_loopctl, {:join, _, _}}, 10_000
    assert :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
  end

  test "after loopctl disconnects it, the client reconnects and rejoins", ctx do
    {pid, _ref} = start_control(ctx.config)
    assert_receive {:test_loopctl, {:join, _, _}}, 5_000

    TestLoopctl.disconnect_runner()

    assert_receive {:test_loopctl, {:connect, _}}, 10_000
    assert_receive {:test_loopctl, {:join, _, _}}, 10_000
    assert :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
  end

  test "a rejoin sends a freshly built payload, not the first join's", ctx do
    TestLoopctl.script_joins([
      {:delay, 500, {:error, %{reason: "rate_limited", max_joins: 30, window_ms: 60_000}}}
    ])

    {_pid, _ref} = start_control(ctx.config)
    assert_receive {:test_loopctl, {:join, _, %{"in_flight" => 0}}}, 5_000

    # A run starts while the refused join is still pending.
    run_dir = Path.join(ctx.config.runs_dir, "live-run")
    File.mkdir_p!(run_dir)

    LoopctlRunner.RunState.update(
      run_dir,
      Map.merge(owner!(), %{"run_id" => "live-run", "status" => "running"})
    )

    assert_receive {:test_loopctl, {:join, _, %{"in_flight" => 1}}}, 10_000
  end

  test "a corrected token file is picked up on the next attempt, without a restart", ctx do
    File.write!(ctx.token_file, "lc_wrong_token")
    {pid, _ref} = start_control(ctx.config)
    assert_receive {:test_loopctl, {:connect, _}}, 5_000
    refute_receive {:test_loopctl, {:join, _, _}}, 500

    File.write!(ctx.token_file, TestLoopctl.get(:token))
    assert_receive {:test_loopctl, {:join, _, _}}, 15_000
    assert :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
  end

  test "backoff is reset by a join, not by a connect that is then dropped", ctx do
    TestLoopctl.script_joins(List.duplicate(:not_authorized_disconnect, 10))
    {pid, _ref} = start_control(ctx.config)

    # Accepted upgrades followed by refusals and drops: attempts must keep growing.
    assert :ok = wait_until(fn -> Control.info(pid).connect_attempts >= 3 end, 15_000)
    refute_receive {:fatal, _}, 100
  end

  test "a refused upgrade is retried with a backoff and never crashes the client", ctx do
    File.write!(ctx.token_file, "lc_wrong_token")
    {pid, _ref} = start_control(ctx.config)

    assert_receive {:test_loopctl, {:connect, _}}, 5_000
    assert_receive {:test_loopctl, {:connect, _}}, 10_000
    refute_receive {:test_loopctl, {:join, _, _}}, 500
    assert Process.alive?(pid)
    assert Control.info(pid).connect_attempts >= 1
  end

  describe "dispatch refusals" do
    @dispatch %{
      "dispatch_id" => "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f",
      "story_id" => "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
      "kind" => "implement",
      "repo" => "mkreyman/home_care_billing",
      "base_branch" => "master",
      "branch" => "loop/story-1",
      "claim_epoch" => 3,
      "wall_clock_seconds" => 3600,
      "max_turns" => 200
    }

    defp joined_control(ctx) do
      # A long interval, so any status seen below was sent for a reason under test.
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
      {pid, _ref} = start_control(slow)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      {pid, "runner:" <> TestLoopctl.get(:runner_id)}
    end

    test "a valid dispatch is refused back to loopctl as dispatches_disabled", ctx do
      {pid, topic} = joined_control(ctx)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert Contract.validate("RunnerDispatchReply", reply) == :ok

      assert reply == %{
               "dispatch_id" => @dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "decision" => "refused",
               "reason" => "dispatches_disabled",
               "detail" => "this runner is not configured to accept dispatches"
             }

      assert Control.info(pid).joined
    end

    test "the foreground dev task refuses a dispatch that the CONFIG would have accepted", ctx do
      # The whole point of the flag, end to end: `mix loopctl.serve` starts this daemon on a
      # config whose accepts_dispatches is TRUE — the normal state of an enrolled machine — and
      # a session started from that shell would inherit the operator's login environment. So the
      # config here says yes and the reply must still be a refusal. Delete the override in
      # Application.foreground_overrides/0 and this dispatch is ACCEPTED, which is what makes
      # this a test of the wiring rather than of the reason string.
      config = %{
        ctx.config
        | control: %{ctx.config.control | accepts_dispatches: true, status_interval_s: 30}
      }

      overrides =
        try do
          System.put_env(LoopctlRunner.Application.refuse_dispatches_var(), "1")
          LoopctlRunner.Application.foreground_overrides()
        after
          System.delete_env(LoopctlRunner.Application.refuse_dispatches_var())
        end

      {pid, _ref} = start_control(config, overrides)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      topic = "runner:" <> TestLoopctl.get(:runner_id)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert Contract.validate("RunnerDispatchReply", reply) == :ok
      assert reply["decision"] == "refused"
      # A DispatchPolicy reason about this process, never a capability claim about the machine.
      assert reply["reason"] == "dispatches_disabled"
      refute reply["reason"] == "kind_not_supported"

      # One reason, two conditions: the detail is the only thing that tells loopctl WHICH, so a
      # reader there does not go looking for a misconfigured machine.
      assert reply["detail"] =~ "mix loopctl.serve"
      assert reply["detail"] =~ "--accept-dispatches"
      refute reply["detail"] == "this runner is not configured to accept dispatches"
      # It leaves the machine: no path, hostname or environment value may ride along.
      refute reply["detail"] =~ ~r"/"
      refute String.contains?(reply["detail"], ctx.root)
      assert byte_size(reply["detail"]) <= 500

      # It still JOINS, and reports draining so loopctl reserves no capacity for it.
      assert %{joined: true, draining: true, accepts_dispatches: false} = Control.info(pid)
    end

    test "under a service manager the config decides, and nothing overrides it", _ctx do
      # The other half: without the marker the task's refusal must not leak into the release
      # path, where the unit's environment is the clean one and the config is the authority.
      System.delete_env(LoopctlRunner.Application.refuse_dispatches_var())
      assert LoopctlRunner.Application.foreground_overrides() == []
    end

    test "a rate-limited dispatch_reply is resent, and does not trigger a status", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "rate_limited"}}])
      {_pid, topic} = joined_control(ctx)
      flush_status()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, first}}, 5_000
      assert_receive {:test_loopctl, {:dispatch_reply, ^first}}, 3_000
      refute_receive {:test_loopctl, {:status, _}}, 1_500
    end

    test "a backlog of rate-limited replies is resent one per interval, not all at once", ctx do
      TestLoopctl.put(:dispatch_reply_floor_ms, 200)
      {_pid, topic} = joined_control(ctx)

      ids =
        for n <- 1..3 do
          id = "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0#{n}"
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", %{@dispatch | "dispatch_id" => id})
          id
        end

      # One accepted at once, two refused; then one per 250ms interval, each past the 200ms
      # floor. Retrying all together would have two collide on every interval.
      Process.sleep(1_500)
      replies = collect_dispatch_replies()
      assert length(replies) == 5
      assert replies |> Enum.map(& &1["dispatch_id"]) |> Enum.uniq() |> Enum.sort() == ids
    end

    test "a reply waiting out a rate limit when the channel drops is resent after the rejoin",
         ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "rate_limited"}}])
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(slow, dispatch_reply_retry_ms: 300)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          topic = "runner:" <> TestLoopctl.get(:runner_id)

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, first}}, 5_000
          # The refusal has reached the runner and the reply is waiting out the rate limit.
          :ok = wait_until(fn -> Control.info(pid).dispatch_reply_backlog == 1 end, 3_000)

          TestLoopctl.disconnect_runner()
          :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          assert_receive {:test_loopctl, {:dispatch_reply, ^first}}, 3_000
          :ok = wait_until(fn -> Control.info(pid).dispatch_reply_backlog == 0 end, 3_000)
        end)

      # The backlog timer is cancelled with the channel: no push is even attempted while down.
      refute log =~ "held until the channel rejoins"
    end

    test "a reply in flight when the channel drops is resent, and a settled answer is not a fault",
         ctx do
      TestLoopctl.put(:dispatch_reply_replies, [:none, {:error, %{reason: "stale_claim_epoch"}}])
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {pid, topic} = joined_control(ctx)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, first}}, 5_000
          :ok = wait_until(fn -> Control.info(pid).dispatch_replies_pending == 1 end, 3_000)

          TestLoopctl.disconnect_runner()
          :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          assert_receive {:test_loopctl, {:dispatch_reply, ^first}}, 3_000
          :ok = wait_until(fn -> Control.info(pid).dispatch_replies_pending == 0 end, 3_000)
        end)

      assert log =~ "no longer needs the resent dispatch_reply (stale_claim_epoch)"
      refute log =~ "refused the dispatch_reply"
    end

    test "a backlog timer message that outlived its timer is ignored, not re-armed", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "rate_limited"}}])
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(slow, dispatch_reply_retry_ms: 5_000)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          topic = "runner:" <> TestLoopctl.get(:runner_id)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, _}}, 5_000
          :ok = wait_until(fn -> Control.info(pid).dispatch_reply_backlog == 1 end, 3_000)

          TestLoopctl.disconnect_runner()
          :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
          # What a timer that fired just before its cancel leaves in the mailbox.
          send(pid, {:send_reply_backlog, make_ref()})
          Process.sleep(200)
          assert Control.info(pid).dispatch_reply_backlog == 1
        end)

      refute log =~ "held until the channel rejoins"
    end

    test "an error reply with no reason is a refusal, not a recorded reply", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [:bare_error])
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {pid, topic} = joined_control(ctx)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, _}}, 5_000
          :ok = wait_until(fn -> Control.info(pid).dispatch_replies_pending == 0 end, 3_000)
          Process.sleep(50)
        end)

      assert log =~ "loopctl refused the dispatch_reply without a reason: :error"
      refute log =~ "recorded the dispatch_reply"
    end

    test "a dispatch_reply refused for a reason retrying cannot fix is logged, not resent", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "stale_claim_epoch"}}])
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log([metadata: [:dispatch_id, :claim_epoch]], fn ->
          {_pid, topic} = joined_control(ctx)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", @dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, _}}, 5_000
          refute_receive {:test_loopctl, {:dispatch_reply, _}}, 1_000
        end)

      assert log =~
               ~r/dispatch_id=#{@dispatch["dispatch_id"]} claim_epoch=3 .*refused the dispatch_reply \(stale_claim_epoch\)/
    end

    test "a malformed dispatch that still carries its id and epoch is refused as other", ctx do
      {_pid, topic} = joined_control(ctx)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", Map.delete(@dispatch, "repo"))

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
      assert detail =~ "missing repo"
    end

    test "a dispatch without a usable id or epoch gets no reply, and the log says so", ctx do
      log =
        capture_log(fn ->
          {_pid, topic} = joined_control(ctx)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", Map.delete(@dispatch, "claim_epoch"))
          refute_receive {:test_loopctl, {:dispatch_reply, _}}, 1_000
        end)

      assert log =~ "dispatch not answered: it carries no usable dispatch_id and claim_epoch"
      refute log =~ "refused"
    end
  end

  describe "trace shipping" do
    @dispatch_id "2e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"

    # A run id of its own per test: a stopped runner's last pushes can still reach the fake
    # after the next test has reset it, and must not land on this test's run.
    setup do
      {:ok, run_id: LoopctlRunner.Session.uuid4()}
    end

    defp dispatched_run(ctx, events, state \\ %{}, name \\ "dispatched-run") do
      run_dir = Path.join(ctx.config.runs_dir, name)
      File.mkdir_p!(run_dir)

      LoopctlRunner.RunState.update(
        run_dir,
        Map.merge(
          %{
            "run_id" => ctx.run_id,
            "dispatch_id" => @dispatch_id,
            "claim_epoch" => 4,
            "status" => "succeeded"
          },
          state
        )
      )

      lines =
        Enum.map_join(events, fn seq ->
          JSON.encode!(%{
            "run_id" => ctx.run_id,
            "seq" => seq,
            "event_id" => Integer.to_string(seq),
            "parent" => if(seq == 0, do: nil, else: "0"),
            "ts" => "2026-09-13T05:00:00Z",
            "type" => "claude.tool_use",
            "data" => %{"n" => seq}
          }) <> "\n"
        end)

      File.write!(Path.join(run_dir, "trace.ndjson"), lines)
      run_dir
    end

    # The run directory must exist BEFORE the control starts, because started_dispatches is
    # rebuilt from the run directories at boot and that is what makes a re-dispatch of this run's
    # own dispatch_id answerable. Its trace must arrive AFTER, because the first trace tick fires
    # at join and would spend the single queued dispatch_not_accepted before any reply is pending.
    # So: an empty trace at boot, events written when the test is ready for them.
    #
    # An empty trace at boot is NOT inert, which is the trap. The run is `succeeded`, so the first
    # poll settles it — last_seq is -1 on an empty file, -1 >= -1, and trace_ship.json is written
    # as done with acked_seq -1 before the events exist. Waiting on that file's EXISTENCE is
    # therefore a race in one direction and vacuous in the other: it can satisfy on the boot
    # marker instead of the abandon marker, and `done: true` is true whether or not anything ever
    # shipped. Every wait below is on CONTENT, and shipped/2 requires the acked seq.
    defp trace_events(ctx, run_dir, events) do
      dispatched_run(ctx, events, %{}, Path.basename(run_dir))
      run_dir
    end

    defp ship_state(run_dir) do
      path = Path.join(run_dir, "trace_ship.json")
      if File.exists?(path), do: JSON.decode!(File.read!(path)), else: nil
    end

    defp abandoned(run_dir, reason) do
      :ok = wait_until(fn -> match?(%{"abandoned" => ^reason}, ship_state(run_dir)) end, 5_000)
    end

    defp shipped(run_dir, through) do
      :ok =
        wait_until(
          fn -> match?(%{"done" => true, "acked_seq" => ^through}, ship_state(run_dir)) end,
          5_000
        )
    end

    defp shipping_control(ctx, opts \\ []) do
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
      {pid, _ref} = start_control(slow, Keyword.merge([trace_poll_ms: 200], opts))
      pid
    end

    test "a finished dispatched run is shipped in full after a cursor, then marked done", ctx do
      run_id = ctx.run_id
      run_dir = dispatched_run(ctx, 0..44)
      pid = shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => first}}}, 3_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => second}}}, 3_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => third}}}, 3_000
      assert Enum.map(first ++ second ++ third, & &1["seq"]) == Enum.to_list(0..44)

      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"done" => true, "acked_seq" => 44} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))

      assert Control.info(pid).trace_acked == %{ctx.run_id => 44}
      refute_receive {:test_loopctl, {:trace_rate_limited, _}}, 500
      refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 300
    end

    test "shipping resumes after what loopctl already holds", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_seqs, %{ctx.run_id => MapSet.new(0..29)})
      dispatched_run(ctx, 0..34)
      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 3_000
      assert Enum.map(events, & &1["seq"]) == Enum.to_list(30..34)
    end

    test "a live run ships what is written and is not marked done", ctx do
      run_id = ctx.run_id

      run_dir =
        dispatched_run(
          ctx,
          0..2,
          Map.merge(owner!(), %{"status" => "running"})
        )

      shipping_control(ctx)
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 5_000
      assert Enum.map(events, & &1["seq"]) == [0, 1, 2]

      # More lines arrive; the idle shipper finds them on its next poll.
      File.write!(
        Path.join(run_dir, "trace.ndjson"),
        File.read!(Path.join(run_dir, "trace.ndjson")) <>
          JSON.encode!(%{
            "run_id" => ctx.run_id,
            "seq" => 3,
            "event_id" => "3",
            "parent" => "0",
            "ts" => "2026-09-13T05:00:01Z",
            "type" => "claude.result",
            "data" => %{}
          }) <> "\n",
        []
      )

      assert_receive {:test_loopctl,
                      {:trace, %{"run_id" => ^run_id, "events" => [%{"seq" => 3}]}}},
                     3_000

      refute File.exists?(Path.join(run_dir, "trace_ship.json"))
    end

    test "a run with no dispatch is never shipped", ctx do
      run_id = ctx.run_id
      run_dir = dispatched_run(ctx, 0..2)
      state = JSON.decode!(File.read!(Path.join(run_dir, "state.json")))

      File.write!(
        Path.join(run_dir, "state.json"),
        JSON.encode!(Map.drop(state, ["dispatch_id", "claim_epoch"]))
      )

      pid = shipping_control(ctx)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      refute_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 1_000
    end

    test "a refusal resending cannot change gives the run up and stops shipping it", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 3_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"abandoned" => "stale_claim_epoch"} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))

      refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 800
      refute_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 10
    end

    test "a per-message refusal every batch would draw gives the run's trace up, not retried",
         ctx do
      # 1.22.0's `claim_epoch_mismatch`: permanent, and about the epoch every batch of the run
      # carries, so the next batch would draw it too. Read into `given_up/0` from the contract;
      # retried as the unexpected reply it was before, it would be pushed for ever.
      run_id = ctx.run_id
      assert "claim_epoch_mismatch" in Control.given_up()
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "claim_epoch_mismatch"}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"abandoned" => "claim_epoch_mismatch"} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))

      refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 800
    end

    test "a rate-limited batch is resent, not skipped", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "rate_limited", min_interval_ms: 50}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => ^events}}}, 3_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)
    end

    test "a rate-limited batch whose interval is not a positive integer is still resent", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "rate_limited", min_interval_ms: 1.5}}])
      dispatched_run(ctx, 0..2)
      pid = shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => ^events}}}, 3_000
      assert Process.alive?(pid)
    end

    test "an event loopctl refuses as too large is resent without its data", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "event_data_too_large", seq: 1}}])
      dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"run_id" => ^run_id, "events" => [_, %{"data" => %{"n" => 1}}, _]}}},
                     5_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"events" => [_, %{"data" => %{"omitted" => "data_too_large"}}, _]}}},
                     3_000
    end

    test "an acknowledgement that does not advance waits out the poll, not a tight resend",
         ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:ack, -1}])
      dispatched_run(ctx, 0..2)
      shipping_control(ctx, trace_poll_ms: 1_000)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 700
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 1_000
    end

    test "a batch loopctl refuses as invalid is narrowed to its event, which ships as a stub",
         ctx do
      run_id = ctx.run_id

      invalid =
        {:error, %{reason: "invalid_payload", details: ["a value was refused by the database"]}}

      TestLoopctl.put(:trace_replies, [invalid, invalid])

      run_dir =
        dispatched_run(
          ctx,
          0..2,
          Map.merge(owner!(), %{"status" => "running"})
        )

      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => [_, _, _]}}},
                     5_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"run_id" => ^run_id, "events" => [%{"seq" => 0, "data" => %{"n" => 0}}]}}},
                     3_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{
                         "run_id" => ^run_id,
                         "events" => [%{"seq" => 0, "type" => "trace.unshippable"}]
                       }}},
                     3_000

      assert_receive {:test_loopctl,
                      {:trace, %{"run_id" => ^run_id, "events" => [%{"seq" => 1}]}}},
                     3_000

      assert_receive {:test_loopctl,
                      {:trace, %{"run_id" => ^run_id, "events" => [%{"seq" => 2}]}}},
                     3_000

      # Past the refused range, batches are full size again.
      more =
        Enum.map_join(3..7, fn seq ->
          JSON.encode!(%{
            "run_id" => run_id,
            "seq" => seq,
            "event_id" => Integer.to_string(seq),
            "parent" => "0",
            "ts" => "2026-09-13T06:00:00Z",
            "type" => "claude.tool_use",
            "data" => %{}
          }) <> "\n"
        end)

      File.write!(Path.join(run_dir, "trace.ndjson"), more, [:append])

      assert_receive {:test_loopctl,
                      {:trace, %{"run_id" => ^run_id, "events" => [_, _, _, _, _]}}},
                     3_000
    end

    test "a size refusal repeated for one event escalates to a stub, then gives the run up",
         ctx do
      run_id = ctx.run_id
      too_large = {:error, %{reason: "event_data_too_large", seq: 1}}
      TestLoopctl.put(:trace_replies, [too_large, too_large, too_large])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"run_id" => ^run_id, "events" => [_, %{"data" => %{"n" => 1}}, _]}}},
                     5_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{
                         "run_id" => ^run_id,
                         "events" => [_, %{"data" => %{"omitted" => "data_too_large"}}, _]
                       }}},
                     3_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{
                         "run_id" => ^run_id,
                         "events" => [_, %{"type" => "trace.unshippable"}, _]
                       }}},
                     3_000

      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"abandoned" => "event_data_too_large"} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))
    end

    test "a one-event batch refused as too large ships that event as a stub", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "batch_too_large", max_events: 20}}])
      dispatched_run(ctx, 0..0)
      shipping_control(ctx)

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"run_id" => ^run_id, "events" => [%{"type" => "claude.tool_use"}]}}},
                     5_000

      assert_receive {:test_loopctl,
                      {:trace,
                       %{"run_id" => ^run_id, "events" => [%{"type" => "trace.unshippable"}]}}},
                     3_000
    end

    test "a refused dispatch's trace is given up at once: dispatch_not_accepted is terminal",
         ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx, trace_poll_ms: 100)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"abandoned" => "dispatch_not_accepted"} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))

      refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 500
    end

    test "while this runner's accept is unacknowledged, dispatch_not_accepted waits instead",
         ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, 0..2)
      pid = shipping_control(ctx, trace_poll_ms: 300)

      # No accept path exists yet (build order step 6): plant the unacknowledged accept a
      # rate-limited reply would leave in the backlog, before the join starts shipping. Its
      # stand-in timer never fires, so the accept stays outstanding.
      accept = %{"dispatch_id" => @dispatch_id, "claim_epoch" => 4, "decision" => "accepted"}

      :sys.replace_state(pid, fn socket ->
        Slipstream.Socket.assign(socket,
          reply_backlog: [{accept, nil, false}],
          reply_timer: {make_ref(), make_ref()}
        )
      end)

      refute Control.info(pid).joined
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      # Not given up: tried again after a poll, and shipped once the refusal is gone.
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 3_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)
      assert %{"done" => true} = JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))
    end

    # The dispatch the run on disk was started from, at whatever epoch a test re-sends it.
    defp this_run(epoch),
      do: %{@dispatch | "dispatch_id" => @dispatch_id, "claim_epoch" => epoch}

    # These drive REAL dispatch sequences rather than planting state: the runner rebuilds
    # started_dispatches from the run directories at boot, so a re-dispatch of a run's own
    # dispatch_id is answered exactly as it would be in production — accepted again at the started
    # epoch, refused at any other.
    #
    # The ORDER is enforced, not hoped for. The first trace tick fires at join, so a run directory
    # present before the control starts would spend the single queued dispatch_not_accepted before
    # any reply is pending. Each test therefore starts the control, waits for the join, makes its
    # replies pending, and only THEN writes the run directory for the next poll to find.
    defp pending_dispatch(topic, payload, decision) do
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", payload)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => ^decision} = reply}}, 5_000
      reply
    end

    defp joined_shipping_control(ctx) do
      pid = shipping_control(ctx, trace_poll_ms: 300)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      {pid, "runner:" <> TestLoopctl.get(:runner_id)}
    end

    test "a refusal at a NEWER epoch proves the claim moved, and the trace is given up", ctx do
      # The runner's own evidence that the row for this run's epoch is superseded: it refused a
      # re-dispatch of the same dispatch at a newer claim_epoch, which is what loopctl reclaiming
      # the story looks like from here. Nothing will move that row, so polling against it is
      # polling for ever.
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, [], %{}, "moved-run")
      {_pid, topic} = joined_shipping_control(ctx)

      # This run's own accept, pending because loopctl does not answer it.
      pending_dispatch(topic, this_run(4), "accepted")
      # And the proof, at a newer epoch.
      assert %{"claim_epoch" => 5} = pending_dispatch(topic, this_run(5), "refused")

      trace_events(ctx, run_dir, 0..2)
      abandoned(run_dir, "dispatch_not_accepted")
    end

    test "a refusal at an OLDER epoch is stale history, and the trace still ships", ctx do
      # The regression an earlier version of this guard introduced, and worse than the bug it was
      # fixing: a refusal left pending from before the claim moved would abandon the trace of a run
      # whose own accept is genuinely in flight — permanently, since TraceShip never revisits a run
      # it gave up on. Neither reply is ever answered here, so the refusal is STILL pending when
      # the trace ships, which is the invariant.
      run_id = ctx.run_id
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, [], %{}, "stale-refusal-run")
      {_pid, topic} = joined_shipping_control(ctx)

      assert %{"claim_epoch" => 3} = pending_dispatch(topic, this_run(3), "refused")
      pending_dispatch(topic, this_run(4), "accepted")

      trace_events(ctx, run_dir, 0..2)
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      # Through seq 2: the boot marker says done at acked_seq -1, so only the seq proves it.
      shipped(run_dir, 2)
    end

    test "a refusal of a MALFORMED redelivery is not a withdrawal of this runner's accept", ctx do
      # A dispatch that fails contract validation never reaches the accept path at all: it is
      # refused with the claim_epoch echoed straight out of the payload just rejected as invalid.
      # Reading any pending refusal for that dispatch_id as a withdrawal therefore destroyed a
      # healthy run's trace on a redelivery loopctl mangled — the same permanent loss, reached
      # from the other side. The runner's accept stands; loopctl records it and answers the later
      # refusal already_replied.
      run_id = ctx.run_id
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, [], %{}, "malformed-redelivery-run")
      {_pid, topic} = joined_shipping_control(ctx)

      pending_dispatch(topic, this_run(4), "accepted")
      # Same dispatch, same epoch, one required field gone.
      assert %{"claim_epoch" => 4} =
               pending_dispatch(topic, Map.delete(this_run(4), "repo"), "refused")

      trace_events(ctx, run_dir, 0..2)
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      shipped(run_dir, 2)
    end

    test "a LATE redelivery at an older epoch does not undo a supersession already recorded",
         ctx do
      # The newest epoch seen is what says how far the claim has moved, and redeliveries are not
      # ordered: a queued epoch-3 copy arriving after the epoch-6 refusal must not overwrite it.
      # Without that, the run whose claim genuinely moved goes back to polling for ever — and no
      # other test can catch it, because storing an OLDER epoch is absorbed by the comparison in
      # accept_outstanding?/3 either way.
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none, :none])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      run_dir = dispatched_run(ctx, [], %{}, "late-older-redelivery-run")
      {_pid, topic} = joined_shipping_control(ctx)

      pending_dispatch(topic, this_run(4), "accepted")
      assert %{"claim_epoch" => 6} = pending_dispatch(topic, this_run(6), "refused")
      # Late, and older than the supersession already recorded.
      assert %{"claim_epoch" => 3} = pending_dispatch(topic, this_run(3), "refused")

      trace_events(ctx, run_dir, 0..2)
      abandoned(run_dir, "dispatch_not_accepted")
    end

    test "a dispatch that is not this runner's is given up at once", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "unknown_dispatch"}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx, trace_poll_ms: 100)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)

      assert %{"abandoned" => "unknown_dispatch"} =
               JSON.decode!(File.read!(Path.join(run_dir, "trace_ship.json")))
    end

    test "a run waiting on loopctl does not hold up the runs after it", ctx do
      waiting_id = ctx.run_id
      ready_id = LoopctlRunner.Session.uuid4()
      # An unexpected reply backs a run off for a poll instead of giving it up.
      TestLoopctl.put(:trace_refuse_runs, %{waiting_id => %{reason: "something_new"}})

      # Run directories are listed in path order: "dispatched-run" comes before "zz-ready".
      dispatched_run(ctx, 0..2)
      ready_dir = dispatched_run(%{ctx | run_id: ready_id}, 0..2, %{}, "zz-ready")

      pid = shipping_control(ctx, trace_poll_ms: 1_000)
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^waiting_id}}}, 5_000

      :ok = wait_until(fn -> File.exists?(Path.join(ready_dir, "trace_ship.json")) end, 3_000)
      assert %{^ready_id => 2} = Control.info(pid).trace_acked

      # The waiting run is retried once a poll, not at the 50ms pace: a handful of pushes in two
      # seconds, where the pace would allow about forty.
      Process.sleep(2_000)
      retries = count_traces(waiting_id, 0)
      assert retries >= 1 and retries <= 5
      # Still waiting, not given up.
      refute File.exists?(Path.join(ctx.config.runs_dir, "dispatched-run/trace_ship.json"))
    end

    test "runs with work take turns rather than one shipping its whole backlog first", ctx do
      long_id = ctx.run_id
      short_id = LoopctlRunner.Session.uuid4()
      long_dir = dispatched_run(ctx, 0..199)
      short_dir = dispatched_run(%{ctx | run_id: short_id}, 0..2, %{}, "zz-short")
      shipping_control(ctx)

      :ok = wait_until(fn -> File.exists?(Path.join(short_dir, "trace_ship.json")) end, 5_000)
      refute File.exists?(Path.join(long_dir, "trace_ship.json"))
      assert_received {:test_loopctl, {:trace, %{"run_id" => ^long_id}}}
    end

    test "a run that starts while another ships its backlog is found within a poll", ctx do
      long_dir = dispatched_run(ctx, 0..399)
      late_id = LoopctlRunner.Session.uuid4()
      shipping_control(ctx, trace_poll_ms: 300)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => _}}}, 5_000
      late_dir = dispatched_run(%{ctx | run_id: late_id}, 0..2, %{}, "zz-late")

      :ok = wait_until(fn -> File.exists?(Path.join(late_dir, "trace_ship.json")) end, 3_000)
      refute File.exists?(Path.join(long_dir, "trace_ship.json"))
    end

    test "a done run whose trace grows afterwards ships the new lines", ctx do
      run_id = ctx.run_id
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 5_000)

      # What the reaper does to a finished run when a later run starts.
      reaped =
        JSON.encode!(%{
          "run_id" => run_id,
          "seq" => 3,
          "event_id" => "3",
          "parent" => "0",
          "ts" => "2026-09-13T06:00:00Z",
          "type" => "run.reaped",
          "data" => %{}
        })

      File.write!(Path.join(run_dir, "trace.ndjson"), reaped <> "\n", [:append])

      assert_receive {:test_loopctl,
                      {:trace, %{"run_id" => ^run_id, "events" => [%{"type" => "run.reaped"}]}}},
                     3_000
    end

    test "a settle that cannot be recorded is logged, and neither crashes nor reships", ctx do
      run_id = ctx.run_id
      run_dir = dispatched_run(ctx, 0..2)
      File.chmod!(run_dir, 0o555)
      on_exit(fn -> File.chmod(run_dir, 0o755) end)

      log =
        capture_log(fn ->
          pid = shipping_control(ctx)
          assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000
          :ok = wait_until(fn -> Control.info(pid).trace_acked == %{run_id => 2} end, 3_000)
          refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 800
          assert Process.alive?(pid)
        end)

      # Settled in memory: not retried, and not logged again, on every later poll.
      assert length(String.split(log, "recording it failed")) == 2
      refute File.exists?(Path.join(run_dir, "trace_ship.json"))
    end

    test "shipping a long trace scans run state on polls, not before every batch", ctx do
      run_id = ctx.run_id
      run_dir = dispatched_run(ctx, 0..199)
      test = self()

      find_runs = fn runs_dir ->
        send(test, :scanned_runs)
        LoopctlRunner.TraceShip.runs(runs_dir)
      end

      shipping_control(ctx, trace_poll_ms: 60_000, trace_find_runs: find_runs)
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 10_000)
      assert_received {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}

      # One scan at the join for a cursor and ten batches; the poll is a minute away.
      assert_received :scanned_runs
      refute_received :scanned_runs
    end

    test "a rejoin asks for the cursor again before shipping on", ctx do
      run_id = ctx.run_id
      # Hold the run live so it is never marked done between the channels.
      run_dir =
        dispatched_run(
          ctx,
          0..2,
          Map.merge(owner!(), %{"status" => "running"})
        )

      pid = shipping_control(ctx)
      assert_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 3_000

      TestLoopctl.disconnect_runner()
      :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
      assert Control.info(pid).trace_acked == %{}
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      assert_receive {:test_loopctl, {:trace_cursor, %{"run_id" => ^run_id}}}, 3_000
      refute File.exists?(Path.join(run_dir, "trace_ship.json"))
    end
  end

  describe "the accept path" do
    alias LoopctlRunner.{DispatchRun, Run, RunState, Session}

    setup ctx do
      repo = git_repo!(Path.join(ctx.root, "repo"))
      # Only a repository that states its mode runs; a test about another mode commits over it.
      File.mkdir_p!(Path.join(repo, ".loopctl"))
      File.write!(Path.join([repo, ".loopctl", "mode"]), "pr\n")
      git!(repo, ["add", ".loopctl/mode"])
      git!(repo, ["commit", "-q", "-m", "mode"])
      fake = Path.join(ctx.root, "fake")
      File.mkdir_p!(fake)
      supervisor = start_supervised!(Task.Supervisor)
      {:ok, fake: fake, run_supervisor: supervisor}
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

    # A joined client that accepts dispatches for mkreyman/fixture, with the fake CLI on PATH in
    # `mode` for as long as the test runs. Every run it started has ended before the test does.
    defp accepting_control(ctx, mode, control \\ %{}, opts \\ []) do
      restore = fake_env!(ctx.fake, [{"FAKE_CLAUDE_MODE", mode}, {"FAKE_AGENTS", "busy"}])
      on_exit(fn -> restore.() end)
      {pid, _ref} = start_accepting(ctx, control, opts)
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
      {pid, "runner:" <> TestLoopctl.get(:runner_id)}
    end

    defp start_accepting(ctx, control, opts) do
      config = %{
        ctx.config
        | control:
            Map.merge(
              %{
                ctx.config.control
                | status_interval_s: 30,
                  repos: ["mkreyman/fixture"],
                  accepts_dispatches: true,
                  min_free_disk_mb: 0
              },
              control
            )
      }

      start_control(
        config,
        Keyword.merge(
          [run_supervisor: ctx.run_supervisor, trace_poll_ms: 200, stage_retry_ms: 50],
          opts
        )
      )
    end

    defp counting_run(test) do
      fn config, story, opts ->
        send(test, {:run_started, story.id})
        Run.execute(config, story, opts)
      end
    end

    # A run of `dispatch` on disk that ended `deadline_passed`, as `Run` leaves one.
    defp deadline_passed_run!(ctx, dispatch) do
      run_dir = Path.join(ctx.config.runs_dir, "deadline-#{dispatch["dispatch_id"]}")
      File.mkdir_p!(run_dir)

      RunState.finish(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "deadline_passed",
          "reached" => "claimed"
        })
      )
    end

    defp runs_done(pid) do
      :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 30_000)
    end

    defp next_stage(timeout \\ 15_000) do
      receive do
        {:test_loopctl, {:stage, payload}} -> payload
      after
        timeout -> flunk("no stage report within #{timeout}ms")
      end
    end

    # Every session_ended already received, taken out of the mailbox.
    defp drain_session_ended(acc \\ []) do
      receive do
        {:test_loopctl, {:session_ended, _}} = message -> drain_session_ended([message | acc])
      after
        0 -> acc
      end
    end

    defp next_session_ended(timeout \\ 15_000) do
      receive do
        {:test_loopctl, {:session_ended, payload}} -> payload
      after
        timeout -> flunk("no session_ended within #{timeout}ms")
      end
    end

    # What a run whose session ran loop-escalate finishes with.
    defp escalated_summary,
      do: %{status: "escalated", reached: "implementing", escalations: ["a business call"]}

    defp end_recorded(run_dir, value),
      do: fn -> match?({:ok, %{"terminal_reported" => ^value}}, RunState.read(run_dir)) end

    test "an accepted dispatch runs, reports its stages in order and ships its trace", ctx do
      {pid, topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      id = dispatch["dispatch_id"]
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert reply == %{"dispatch_id" => id, "claim_epoch" => 3, "decision" => "accepted"}

      worktree =
        LoopctlRunner.Worktree.path_for(
          Path.join(ctx.root, "repo"),
          DispatchRun.story_id(dispatch["story_id"])
        )

      assert next_stage() == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "from" => "claimed",
               "to" => "worktree",
               "effects" => %{"branch" => dispatch["branch"], "worktree_path" => worktree}
             }

      assert %{"from" => "worktree", "to" => "implementing"} = next_stage()

      # The session delivers, so the run reports its END, not a stage: no `-> escalated`.
      assert next_session_ended() == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "reason" => "completed",
               # The fake CLI's result line says num_turns 2; with no origin the runner cannot
               # tell what it left behind, so `work_left_behind` is omitted (contract 1.27.0).
               "turns_used" => 2
             }

      # The run's state is bound to the dispatch, so its trace ships.
      assert [{run_dir, state}] = RunState.all(ctx.config.runs_dir)
      assert %{"dispatch_id" => ^id, "claim_epoch" => 3, "status" => "succeeded"} = state
      assert state["story_id"] == dispatch["story_id"]
      run_id = state["run_id"]
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 10_000

      # The session got the fenced story.
      argv = File.read!(Path.join(ctx.fake, "argv"))

      assert argv =~
               "<<<UNTRUSTED story.title>>>\nAdd a greeting\n<<<END UNTRUSTED story.title>>>"

      runs_done(pid)
      refute_receive {:test_loopctl, {:stage, _}}, 300
      refute_receive {:test_loopctl, {:session_ended, _}}, 300
      :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
      :ok = wait_until(end_recorded(run_dir, true))
    end

    # Commits `.loopctl/mode` holding `content` on the fixture's master, which is the base every
    # dispatch here names; the fixture has no origin, so the base as given is what is read.
    defp commit_mode!(ctx, content) do
      repo = Path.join(ctx.root, "repo")
      File.mkdir_p!(Path.join(repo, ".loopctl"))
      File.write!(Path.join([repo, ".loopctl", "mode"]), content)
      git!(repo, ["add", ".loopctl/mode"])
      git!(repo, ["commit", "-q", "-m", "mode"])
      repo
    end

    test "a repository still in thread mode is refused before a session, naming the retirement",
         ctx do
      # loopctl retired change threads in contract 1.23.0, so nothing merges a thread session's
      # pushes: the run is refused rather than started on work that could never land.
      commit_mode!(ctx, "thread\n")

      {pid, topic} = accepting_control(ctx, "stream")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert %{"to" => "worktree"} = next_stage()

      assert %{"from" => "worktree", "to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "run ended refused"
      assert reason =~ "delivery mode thread in .loopctl/mode was retired"
      runs_done(pid)
      refute_receive {:test_loopctl, {:session_ended, _}}, 500

      refute File.exists?(Path.join(ctx.fake, "argv"))
      refute File.exists?(Path.join(ctx.fake, "env"))
    end

    test "the mode is the commit the tree was cut from, not an unfetched origin ref", ctx do
      # refs/remotes/origin/master says pr and was never fetched past; the local master the
      # worktree is cut from says thread. The run reads thread's tree, so it is refused.
      repo = Path.join(ctx.root, "repo")
      git!(repo, ["update-ref", "refs/remotes/origin/master", git!(repo, ["rev-parse", "HEAD"])])
      commit_mode!(ctx, "thread\n")

      {pid, topic} = accepting_control(ctx, "stream")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert %{"to" => "worktree"} = next_stage()

      assert %{"from" => "worktree", "to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "delivery mode thread in .loopctl/mode was retired"
      runs_done(pid)

      refute File.exists?(Path.join(ctx.fake, "argv"))
    end

    test "a repository with no .loopctl/mode is refused before a session, never run as pr", ctx do
      repo = Path.join(ctx.root, "repo")
      git!(repo, ["rm", "-q", ".loopctl/mode"])
      git!(repo, ["commit", "-q", "-m", "no mode"])

      {pid, topic} = accepting_control(ctx, "stream")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert %{"to" => "worktree"} = next_stage()

      assert %{"from" => "worktree", "to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "run ended refused"
      assert reason =~ "other: repository has no .loopctl/mode"
      runs_done(pid)
      refute_receive {:test_loopctl, {:session_ended, _}}, 500

      refute File.exists?(Path.join(ctx.fake, "argv"))
    end

    test "a malformed .loopctl/mode is refused naming it, never read as pr", ctx do
      commit_mode!(ctx, "threads\n")

      {pid, topic} = accepting_control(ctx, "stream")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert %{"to" => "worktree"} = next_stage()

      assert %{"from" => "worktree", "to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "run ended refused"
      assert reason =~ ~s(malformed delivery mode "threads")
      runs_done(pid)

      refute File.exists?(Path.join(ctx.fake, "argv"))
    end

    test "a run that does not finish reports its outcome, escalation text included", ctx do
      {pid, topic} = accepting_control(ctx, "escalate_and_exit")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

      assert %{"to" => "worktree"} = next_stage()
      assert %{"to" => "implementing"} = next_stage()
      assert %{"to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "run ended escalated"
      assert reason =~ "session exit reason escalated"
      assert reason =~ "The story contradicts an existing KB decision."
      # Behind the escalation: the session's end, which `completed` reports without moving it.
      assert %{"reason" => "completed"} = next_session_ended()
      runs_done(pid)
    end

    test "a run that never gets a worktree escalates from claimed", ctx do
      {pid, topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      # A leftover branch carrying a commit that never shipped: an empty one is retired and
      # re-cut, so only unshipped work makes the cut refuse.
      repo = Path.join(ctx.root, "repo")
      unshipped = git!(repo, ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "unshipped"])
      git!(repo, ["branch", dispatch["branch"], unshipped])
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert %{"from" => "claimed", "to" => "escalated", "reason" => reason} = next_stage()
      assert reason =~ "run ended failed"
      assert reason =~ "already exists without a worktree"
      runs_done(pid)
      refute_receive {:test_loopctl, {:session_ended, _}}, 500
    end

    test "a session that runs out of turns is reported max_turns_exceeded", ctx do
      {pid, topic} = accepting_control(ctx, "max_turns")
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert %{"to" => "worktree"} = next_stage()
      assert %{"to" => "implementing"} = next_stage()

      assert next_session_ended() == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "reason" => "max_turns_exceeded",
               # The fake CLI's error_max_turns result line says num_turns 5 (contract 1.27.0).
               "turns_used" => 5
             }

      runs_done(pid)
      refute_receive {:test_loopctl, {:stage, _}}, 300
    end

    test "a run whose task dies before it has a run directory is escalated from claimed", ctx do
      # No run directory was announced, so no session can have started: there is no session to
      # report ended, and the story goes to a human rather than back to the queue.
      {pid, topic} =
        accepting_control(ctx, "stream", %{}, run: fn _config, _story, _opts -> exit(:boom) end)

      capture_log(fn ->
        dispatch = story_dispatch()
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

        assert %{"dispatch_id" => id, "from" => "claimed", "to" => "escalated"} = next_stage()
        assert id == dispatch["dispatch_id"]
        runs_done(pid)
        refute_receive {:test_loopctl, {:session_ended, _}}, 300
      end)
    end

    test "a run whose task dies after its session escalated is reported escalated", ctx do
      runs_dir = ctx.config.runs_dir

      # What a run killed mid-session leaves: the stage it recorded, and its session's escalation.
      run = fn _config, _story, opts ->
        run_dir = Path.join(runs_dir, "killed-after-escalating")
        File.mkdir_p!(run_dir)
        File.write!(Path.join(run_dir, "escalations.ndjson"), ~s({"reason":"a business call"}\n))
        RunState.update(run_dir, %{"status" => "running", "reached" => "implementing"})
        opts[:on_stage].({:started, %{run_id: Session.uuid4(), run_dir: run_dir}})
        exit(:boom)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)

      capture_log(fn ->
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

        assert %{"to" => "escalated", "reason" => reason} = next_stage()
        assert reason =~ "the session escalated: a business call"
        # `crashed` would release the claim over the escalation and re-queue the story.
        assert %{"reason" => "completed"} = next_session_ended()
        runs_done(pid)
      end)

      # Closed as it was reported, so a later Control reading it back reports the same end.
      assert {:ok, %{"status" => "escalated"}} =
               RunState.read(Path.join(runs_dir, "killed-after-escalating"))
    end

    test "a run whose task dies with its session alive has the session ended before session_ended",
         ctx do
      # An implement session outliving its run's task can still push. Reported `crashed` while it
      # runs, loopctl frees the slot and releases the claim under a session that is still working.
      # One that ignores TERM takes the whole grace (2s here) to end, so what is reported inside
      # that window says which came first.
      session = live_session!(true)
      tree_file = Path.join(ctx.root, "implement.tree")
      File.write!(tree_file, "#{session} #{LoopctlRunner.TestSupport.utc_start_time(session)}\n")
      runs_dir = ctx.config.runs_dir
      test = self()

      run = fn _config, _story, opts ->
        run_dir = Path.join(runs_dir, "killed-mid-session")
        File.mkdir_p!(run_dir)

        RunState.update(
          run_dir,
          Map.merge(owner!(), %{
            "status" => "running",
            "reached" => "implementing",
            "session_id" => Session.uuid4(),
            "tree_file" => tree_file
          })
        )

        opts[:on_stage].({:started, %{run_id: Session.uuid4(), run_dir: run_dir}})
        send(test, :stalled)
        Process.sleep(:infinity)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)

      capture_log(fn ->
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
        assert_receive :stalled, 10_000
        :ok = wait_until(fn -> Control.info(pid).run_dirs != %{} end)
        [task] = Task.Supervisor.children(ctx.run_supervisor)
        Process.exit(task, :kill)

        refute_receive {:test_loopctl, {:session_ended, _}}, 1_200
        assert os_pid_alive?(session)

        assert next_session_ended()["reason"] == "crashed"
        refute os_pid_alive?(session)
        runs_done(pid)
      end)
    end

    test "each budget and ending is the reason its summary names", ctx do
      {pid, _topic} = accepting_control(ctx, "stream")

      for {summary, reason} <- [
            {%{status: "wall_clock_exceeded", reached: "implementing"}, "wall_clock_exceeded"},
            {%{status: "failed", reached: "implementing"}, "crashed"},
            {%{status: "parked", reached: "implementing"}, "crashed"}
          ] do
        binding = DispatchRun.binding(story_dispatch())
        send(pid, {:run_stage, binding, {:finished, summary}})
        assert next_session_ended(5_000)["reason"] == reason
      end

      refute_receive {:test_loopctl, {:stage, _}}, 300
    end

    test "an accept loopctl refuses never starts the run, and frees its capacity", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "stale_claim_epoch"}}])
      test = self()
      refused = story_dispatch()
      refused_story = DispatchRun.story_id(refused["story_id"])

      log =
        capture_log(fn ->
          {pid, topic} =
            accepting_control(ctx, "stream", %{max_sessions: 1}, run: counting_run(test))

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", refused)
          assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
          :ok = wait_until(fn -> Control.info(pid).pending_starts == [] end, 3_000)
          refute_receive {:run_started, ^refused_story}, 500

          # The refused start no longer holds the only session.
          accepted = story_dispatch()
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", accepted)
          assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
          assert %{"decision" => "accepted"} = reply
          assert_receive {:run_started, _}, 5_000
          runs_done(pid)
          refute_received {:run_started, ^refused_story}
        end)

      assert log =~
               "did not record this runner's accept of dispatch #{refused["dispatch_id"]} " <>
                 "(stale_claim_epoch); its run is not started"

      # Nothing ran under that claim, so its end is neither recorded nor treated as a stop.
      refute LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, refused["dispatch_id"], 3)
      refute log =~ "which ends"
    end

    test "the run starts only once loopctl acknowledges the accept", ctx do
      TestLoopctl.put(:dispatch_reply_replies, [{:error, %{reason: "rate_limited"}}])
      test = self()

      {pid, topic} =
        accepting_control(ctx, "stream", %{},
          run: counting_run(test),
          dispatch_reply_retry_ms: 1_000
        )

      dispatch = story_dispatch()
      id = dispatch["dispatch_id"]
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, first}}, 5_000
      :ok = wait_until(fn -> Control.info(pid).dispatch_reply_backlog == 1 end, 3_000)

      # Waiting out the rate limit: counted, not started.
      assert Control.info(pid).pending_starts == [id]
      refute_receive {:run_started, _}, 600

      assert_receive {:test_loopctl, {:dispatch_reply, ^first}}, 3_000
      assert_receive {:run_started, _}, 3_000
      runs_done(pid)
    end

    test "a restarted Control answers a dispatch already bound on disk and starts nothing", ctx do
      test = self()
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "earlier-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded"
        })
      )

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert reply == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "decision" => "accepted"
             }

      refute_receive {:run_started, _}, 1_000
      assert %{pending_starts: [], runs_in_flight: []} = Control.info(pid)
    end

    test "a stage message for a dispatch this Control did not start opens its stream", ctx do
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      send(pid, {:run_stage, binding, {:implementing, %{}}})

      assert next_stage(5_000) == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "from" => "worktree",
               "to" => "implementing"
             }

      send(
        pid,
        {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
      )

      assert %{"reason" => "completed"} = next_session_ended(5_000)
      refute_receive {:test_loopctl, {:stage, _}}, 300
      :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)
    end

    test "a run's session_ended is never held behind a checkpoints.log an older build left",
         ctx do
      # Thread-mode checkpoint reporting retired with contract 1.23.0: loopctl answers the
      # checkpoint event unknown_event, so an end held behind one would never be sent.
      {pid, _ref} = start_accepting(ctx, %{}, [])
      :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)
      run_dir = Path.join(ctx.config.runs_dir, "old-thread-run")
      File.mkdir_p!(run_dir)
      LoopctlRunner.RunState.update(run_dir, Map.put(binding, "status", "failed"))

      File.write!(
        Path.join(run_dir, "checkpoints.log"),
        "#{String.duplicate("a", 40)} #{String.duplicate("b", 40)}\n"
      )

      send(
        pid,
        {:run_stage, binding,
         {:finished, %{status: "failed", reached: "implementing", run_dir: run_dir}}}
      )

      assert %{"reason" => "crashed"} = next_session_ended(5_000)
      refute File.exists?(Path.join(run_dir, "checkpoints.sent"))
    end

    test "a run outliving its Control reports its stages to the one that replaces it", ctx do
      name = :"control_#{System.unique_integer([:positive])}"

      slow_run = fn config, story, opts ->
        Process.sleep(1_500)
        Run.execute(config, story, opts)
      end

      {first, topic} = accepting_control(ctx, "stream", %{}, run: slow_run, name: name)
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      id = dispatch["dispatch_id"]
      :ok = wait_until(fn -> Control.info(first).runs_in_flight == [id] end, 5_000)

      GenServer.stop(first)
      {second, _ref} = start_accepting(ctx, %{}, name: name)
      :ok = wait_until(fn -> Control.info(second).joined end, 5_000)

      assert %{"dispatch_id" => ^id, "from" => "claimed", "to" => "worktree"} = next_stage()
      assert %{"from" => "worktree", "to" => "implementing"} = next_stage()
      assert %{"dispatch_id" => ^id, "reason" => "completed"} = next_session_ended()
    end

    test "a null list item is refused as other, and Control keeps running", ctx do
      {pid, topic} = accepting_control(ctx, "stream")

      for key <- ["acceptance_criteria", "test_cases", "touches"] do
        dispatch = story_dispatch() |> put_in(["story", key], [nil])
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

        assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
        # Contract 1.5.0 types the story, so its own validation refuses the null first.
        assert detail =~ "story.#{key}[0]"
      end

      assert Process.alive?(pid)
      assert Control.info(pid).joined
    end

    test "an exception while deciding a dispatch is refused, naming only its kind", ctx do
      decide = fn _dispatch, _config, _state -> raise ArgumentError, "quoted payload text" end

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "stream", %{}, decide: decide)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
          assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

          assert reply["decision"] == "refused"
          assert reply["reason"] == "other"
          assert reply["detail"] == "the runner failed deciding this dispatch (ArgumentError)"
          assert Process.alive?(pid)
          assert Control.info(pid).joined
        end)

      assert log =~ "raised; refusing it"
      assert log =~ "quoted payload text"
    end

    test "an unreadable load reading does not refuse a dispatch for disk", ctx do
      test = self()
      measure = fn _path, _last -> {:error, "loadavg_1m"} end

      {pid, topic} =
        accepting_control(ctx, "stream", %{min_free_disk_mb: 1},
          measure: measure,
          run: counting_run(test)
        )

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert %{"decision" => "accepted"} = reply
      assert_receive {:run_started, _}, 5_000
      runs_done(pid)
    end

    test "a stream opened on demand retries its terminal report from the stage the refusal names",
         ctx do
      # The refusal CARRIES THE ROW (contract 1.11.0), so the retry goes from where loopctl says
      # the story is — not from the next entry of a list of stages it might be at. `claimed` is
      # deliberately not the stage the old walk would have tried next.
      stale = {:error, %{reason: "stale_stage", stage: "claimed"}}
      TestLoopctl.put(:stage_replies, [stale, :ok])
      {pid, _topic} = accepting_control(ctx, "stream")
      binding = DispatchRun.binding(story_dispatch())

      send(pid, {:run_stage, binding, {:finished, escalated_summary()}})

      assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} = next_stage()

      assert next_stage() == %{
               "dispatch_id" => binding["dispatch_id"],
               "claim_epoch" => 3,
               "from" => "claimed",
               "to" => "escalated",
               "edge" => "session_escalated",
               "reason" => reason
             }

      assert reason =~ "the session escalated: a business call"
      # The escalation settled, and the session's end goes behind it.
      assert %{"reason" => "completed"} = next_session_ended()
      refute_receive {:test_loopctl, {:stage, _}}, 800
      assert Control.info(pid).stage_reports_pending == 0
    end

    test "a stream Control started itself retries its terminal report where the row says", ctx do
      stale = {:error, %{reason: "stale_stage", stage: "claimed"}}
      TestLoopctl.put(:stage_replies, [:ok, :ok, stale, :ok])

      capture_log(fn ->
        {pid, topic} = accepting_control(ctx, "escalate_and_exit")
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

        assert %{"to" => "worktree"} = next_stage()
        assert %{"to" => "implementing"} = next_stage()
        assert %{"from" => "implementing", "to" => "escalated"} = next_stage()
        assert %{"from" => "claimed", "to" => "escalated", "reason" => reason} = next_stage()
        assert reason =~ "run ended escalated"
        runs_done(pid)
        refute_receive {:test_loopctl, {:stage, _}}, 1_000
        assert Control.info(pid).stage_reports_pending == 0
      end)
    end

    test "a row that keeps moving is followed, and no stage is reported from twice", ctx do
      # Each refusal names where the row is NOW, so the retries follow it rather than walking a
      # fixed order — here backwards, which no list written in this repo would have produced.
      TestLoopctl.put(:stage_replies, [
        {:error, %{reason: "stale_stage", stage: "implementing"}},
        {:error, %{reason: "stale_stage", stage: "worktree"}},
        {:error, %{reason: "stale_stage", stage: "reviewing"}},
        :ok
      ])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream")
        binding = DispatchRun.binding(story_dispatch())

        # The replacement guesses the story is at worktree; the intermediate is refused and the
        # intermediates stop, which is unchanged — only the terminal report is retried.
        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"from" => "worktree", "to" => "implementing"} = next_stage(5_000)

        send(pid, {:run_stage, binding, {:finished, escalated_summary()}})

        assert %{"from" => "implementing", "to" => "escalated"} = next_stage(5_000)
        assert %{"from" => "worktree", "to" => "escalated"} = next_stage(5_000)

        assert %{"from" => "reviewing", "to" => "escalated", "reason" => reason} =
                 next_stage(5_000)

        assert reason =~ "run ended escalated"
        refute_receive {:test_loopctl, {:stage, _}}, 800
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
      end)
    end

    test "a stage report refused as ending the claim stops the session, and only session_ended goes",
         ctx do
      # contract 1.22.0, `claim_ending_errors.stage`, read rather than typed. The claim ends on the
      # FIRST report, while the run builds its prompt: either the run reads the claim's marker
      # before its session and starts none, or the session had just started and is stopped. Either
      # way the run is over well inside the 30s a hang session would otherwise run.
      reasons = Contract.claim_ending_errors("stage")
      assert reasons != []

      for reason <- reasons do
        TestLoopctl.put(:stage_replies, [{:error, %{reason: reason}}])
        dispatch = story_dispatch()

        log =
          capture_log(fn ->
            {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
            TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

            assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
            :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 15_000)

            # Nothing more of its work: no `-> implementing`, and no `-> escalated` either. A
            # session that had started is reported `crashed`, one that never did is not reported.
            refute_receive {:test_loopctl, {:stage, _}}, 500

            for {:test_loopctl, {:session_ended, ended}} <- drain_session_ended(),
                do: assert(ended["reason"] == "crashed")

            GenServer.stop(pid)
          end)

        # One marker for the claim, so a run of it and a Control that starts over both honour it.
        assert LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, dispatch["dispatch_id"], 3)

        assert log =~ "(#{reason}), which ends the claim it ran under", reason
      end
    end

    test "a claim that ended mid-run takes no terminal escalation, and its session_ended goes",
         ctx do
      # "send that dispatch no more messages of its work (the events keyed here)": `stage` is
      # keyed, so the run's `-> escalated` is not sent after the claim ended — only the
      # `session_ended` that "follows its own rules".
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)
        binding = DispatchRun.binding(story_dispatch())

        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"from" => "worktree", "to" => "implementing"} = next_stage()
        # The refusal is settled BEFORE the run ends, so the escalation is one queued after the
        # claim ended rather than one already queued and dropped with it.
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)

        send(pid, {:run_stage, binding, {:finished, escalated_summary()}})
        assert %{"reason" => "completed"} = next_session_ended()
        refute_receive {:test_loopctl, {:stage, _}}, 800
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
      end)
    end

    test "a claim ended while a stage report is in flight drops it, and session_ended alone goes",
         ctx do
      # The report is never answered; the claim ends meanwhile on a TRACE refusal. Its reply,
      # whenever it comes, answers nothing that is still owed — and waiting for it would hold the
      # `session_ended` behind a push that may never be answered.
      TestLoopctl.put(:stage_replies, [:none])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)

        binding =
          DispatchRun.binding(
            story_dispatch(%{"dispatch_id" => @dispatch_id, "claim_epoch" => 4})
          )

        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"from" => "worktree", "to" => "implementing"} = next_stage()

        dispatched_run(Map.put(ctx, :run_id, Session.uuid4()), 0..2)
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 10_000)

        summary = %{status: "succeeded", reached: "implementing"}
        send(pid, {:run_stage, binding, {:finished, summary}})

        assert next_session_ended() == %{
                 "dispatch_id" => @dispatch_id,
                 "claim_epoch" => 4,
                 "reason" => "completed"
               }

        refute_receive {:test_loopctl, {:stage, _}}, 500
      end)
    end

    test "a stage report refused with a per-message code drops that report only", ctx do
      # 1.22.0's `claim_epoch_mismatch` and `wrong_dispatch_kind` — and every other permanent
      # refusal that neither ends the claim nor carries a condition — refuse the message that drew
      # them and nothing else: never resent, the NEXT report still goes, and the session — which
      # takes ~2.5s here — runs to its own end rather than being stopped.
      for reason <- ~w(claim_epoch_mismatch wrong_dispatch_kind) do
        refute reason in Contract.claim_ending_errors("stage")
        TestLoopctl.put(:stage_replies, [{:error, %{reason: reason}}])

        log =
          capture_log(fn ->
            {pid, topic} =
              accepting_control(ctx, "quiet_then_result", %{}, session_stop_retry_ms: 100)

            TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

            assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
            # From the stage the row is at (`claimed`) when the refusal came first; from the
            # dropped report's `to` when this one was already queued behind it.
            assert %{"to" => "implementing"} = next_stage()
            assert %{"reason" => "completed"} = next_session_ended(20_000)
            runs_done(pid)
            refute_receive {:test_loopctl, {:stage, _}}, 300
            GenServer.stop(pid)
          end)

        assert log =~ "(#{reason}); that report is dropped, and the next one still goes", reason
        refute log =~ "which ends the", reason
      end
    end

    test "dispatch_not_accepted on a stage report with no accept outstanding ends the run", ctx do
      # `permanent_error_conditions`: with no accept of ours in flight, "give the run up". The run
      # ends — its session stopped, its intermediates stopped — but the claim stands, so its end is
      # still reported: here the `session_ended` of the session that was stopped.
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
          assert %{"reason" => "crashed"} = next_session_ended(20_000)
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 500
          GenServer.stop(pid)
        end)

      assert log =~
               "(dispatch_not_accepted, with no accept of this runner's outstanding), " <>
                 "which ends the run"
    end

    test "a run ended while its claim stands still reports its whole end", ctx do
      # Where the run's end differs from the claim's: loopctl still holds this claim, so the
      # escalation the run ended with and its `session_ended` both go, answered by their own rules.
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "dispatch_not_accepted"}}])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)
        binding = DispatchRun.binding(story_dispatch())

        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"from" => "worktree", "to" => "implementing"} = next_stage()
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)

        send(pid, {:run_stage, binding, {:finished, escalated_summary()}})
        assert %{"from" => "implementing", "to" => "escalated"} = next_stage()
        assert %{"reason" => "completed"} = next_session_ended()
      end)
    end

    test "a stale_stage naming a stage no transition leaves ends the run mid-session", ctx do
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage", stage: "escalated"}}])

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

          assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
          assert %{"reason" => "crashed"} = next_session_ended(20_000)
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 500
          GenServer.stop(pid)
        end)

      assert log =~ "the story is at escalated, which no transition leaves), which ends the run"
    end

    test "dispatch_not_accepted on a stage report waits while this runner's accept is in flight",
         ctx do
      # The accept for the same dispatch and epoch is never answered, so it is still outstanding:
      # the refusal is the one case worth retrying, and the report goes again.
      dispatch = story_dispatch()
      TestLoopctl.put(:dispatch_reply_replies, [:none])
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "dispatch_not_accepted"}}, :ok])

      capture_log(fn ->
        {pid, topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

        binding = DispatchRun.binding(dispatch)
        send(pid, {:run_stage, binding, {:implementing, %{}}})
        first = next_stage()
        assert %{"from" => "worktree", "to" => "implementing"} = first
        assert next_stage() == first
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
      end)
    end

    test "a trace batch refused dispatch_not_accepted with no accept outstanding ends the run",
         ctx do
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "dispatch_not_accepted"}}])
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert %{"reason" => "crashed"} = next_session_ended(20_000)
          runs_done(pid)
          GenServer.stop(pid)
        end)

      assert log =~
               "loopctl refused trace for dispatch #{dispatch["dispatch_id"]} " <>
                 "(dispatch_not_accepted, with no accept of this runner's outstanding), " <>
                 "which ends the run"
    end

    test "a claim-ending trace refusal of an OLDER epoch ends that claim, not the newer stream's",
         ctx do
      # The stream here is the dispatch's claim at epoch 4; the refused trace is a run of the same
      # dispatch at epoch 3. The refusal ends epoch 3's claim — recorded beside that run — and
      # nothing of epoch 4's: its run still reports its whole end.
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      log =
        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)

          binding =
            DispatchRun.binding(
              story_dispatch(%{"dispatch_id" => @dispatch_id, "claim_epoch" => 4})
            )

          send(pid, {:run_stage, binding, {:implementing, %{}}})
          assert %{"claim_epoch" => 4, "to" => "implementing"} = next_stage()

          old =
            dispatched_run(Map.put(ctx, :run_id, Session.uuid4()), 0..2, %{"claim_epoch" => 3})

          :ok =
            wait_until(
              fn -> LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, @dispatch_id, 3) end,
              10_000
            )

          assert old

          send(pid, {:run_stage, binding, {:finished, escalated_summary()}})
          assert %{"claim_epoch" => 4, "to" => "escalated"} = next_stage()
          assert %{"claim_epoch" => 4, "reason" => "completed"} = next_session_ended()
        end)

      # Nothing of epoch 3 runs here: the expected end of a claim this process holds nothing of,
      # not an error or a warning.
      refute log =~ "which ends that claim"
    end

    test "a stream-less run's stop keeps looking while the run is in flight, and ends with it",
         ctx do
      # No stream: a run a predecessor started. The claim ends on its trace, and the stop follows
      # the run directories it read once — for as long as any is still in flight, whatever its kind.
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)

        live =
          dispatched_run(
            Map.put(ctx, :run_id, Session.uuid4()),
            0..2,
            Map.merge(%{"status" => "running"}, owner!())
          )

        :ok = wait_until(fn -> Control.info(pid).session_stops_pending == 1 end, 10_000)
        Process.sleep(600)
        assert Control.info(pid).session_stops_pending == 1

        RunState.update(live, %{"status" => "succeeded"})
        :ok = wait_until(fn -> Control.info(pid).session_stops_pending == 0 end, 5_000)
      end)
    end

    test "a claim's end cancels the backoff of the report it dropped", ctx do
      # The report is rate-limited and waiting out a 5s backoff when the claim ends. What it waited
      # for is never sent, so the `session_ended` behind it goes at once, not after the backoff.
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "rate_limited"}}])
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])

      capture_log(fn ->
        {pid, _topic} =
          accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100, stage_retry_ms: 5_000)

        binding =
          DispatchRun.binding(
            story_dispatch(%{"dispatch_id" => @dispatch_id, "claim_epoch" => 4})
          )

        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"to" => "implementing"} = next_stage()

        run = dispatched_run(Map.put(ctx, :run_id, Session.uuid4()), 0..2)
        assert run

        :ok =
          wait_until(
            fn -> LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, @dispatch_id, 4) end,
            3_000
          )

        send(
          pid,
          {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
        )

        assert %{"claim_epoch" => 4, "reason" => "completed"} = next_session_ended(2_000)
        refute_receive {:test_loopctl, {:stage, _}}, 300
        assert Control.info(pid).stage_reports_pending == 0
      end)
    end

    test "a dispatch whose claim is recorded over starts no session and sends none of its work",
         ctx do
      # The marker is there before the run: its stream is opened ending that claim, and the run reads
      # the marker immediately before its session and starts none. Its only end, an escalation, is
      # not sent and is recorded refused.
      dispatch = story_dispatch()
      id = dispatch["dispatch_id"]

      :ok =
        LoopctlRunner.ClaimEnded.record(ctx.config.runs_dir, id, 3, "stage", "stale_claim_epoch")

      capture_log(fn ->
        {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        # The run's own end, not "nothing in flight", which holds before the dispatch is read.
        :ok =
          wait_until(
            fn ->
              Enum.any?(RunState.all(ctx.config.runs_dir), fn {_, state} ->
                state["dispatch_id"] == id and state["status"] == "claim_ended"
              end)
            end,
            15_000
          )

        :ok = wait_until(fn -> Control.info(pid).runs_in_flight == [] end, 15_000)
        refute_receive {:test_loopctl, {:stage, _}}, 500
        refute_received {:test_loopctl, {:session_ended, _}}
      end)

      assert [{run_dir, %{"status" => "claim_ended"} = state}] =
               for(
                 {_, %{"dispatch_id" => ^id}} = run <- RunState.all(ctx.config.runs_dir),
                 do: run
               )

      refute Map.has_key?(state, "session_id")
      :ok = wait_until(end_recorded(run_dir, "refused"), 3_000)
    end

    test "a dropped intermediate report leaves the stream at the stage the row is at", ctx do
      # `worktree -> implementing` is refused for itself alone; loopctl's row stays at `worktree`,
      # so the run's end is reported from there, not from the stage that was never recorded.
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "claim_epoch_mismatch"}}])

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream")
        binding = DispatchRun.binding(story_dispatch())

        send(pid, {:run_stage, binding, {:implementing, %{}}})
        assert %{"from" => "worktree", "to" => "implementing"} = next_stage()
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)

        send(pid, {:run_stage, binding, {:finished, escalated_summary()}})
        assert %{"from" => "worktree", "to" => "escalated"} = next_stage()
      end)
    end

    test "a stop drops a run whose session is gone, while that run tears down", ctx do
      # The run is still in flight, but its process group is dead: nothing is left to stop, so the
      # stop does not keep re-running end_session on it through its teardown.
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "stale_claim_epoch"}}])
      {dead, 0} = System.cmd("sh", ["-c", "echo $$"])
      dead = dead |> String.trim() |> String.to_integer()

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)

        dispatched_run(
          Map.put(ctx, :run_id, Session.uuid4()),
          0..2,
          Map.merge(%{"status" => "running", "pgid" => dead}, owner!())
        )

        :ok =
          wait_until(
            fn -> LoopctlRunner.ClaimEnded.ended?(ctx.config.runs_dir, @dispatch_id, 4) end,
            10_000
          )

        :ok = wait_until(fn -> Control.info(pid).session_stops_pending == 0 end, 3_000)
      end)
    end

    test "a restarted Control sends a finished run's end at once, whatever checkpoints.log it left",
         ctx do
      # An older build's thread run left recorded pushes; nothing reports them now (contract
      # 1.23.0), so its end is not held behind them.
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "recovered-thread-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "failed",
          "reached" => "implementing"
        })
      )

      File.write!(
        Path.join(run_dir, "checkpoints.log"),
        "#{String.duplicate("a", 40)} #{String.duplicate("b", 40)}\n"
      )

      capture_log(fn ->
        {pid, _ref} = start_accepting(ctx, %{}, [])
        :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

        assert %{"reason" => "crashed"} = next_session_ended(5_000)
      end)
    end

    test "a restarted Control retires an unreported review run an older build left, sending nothing",
         ctx do
      # Contract 1.23.0 retired the review kind: its judgements' events answer unknown_event, and
      # the stage stream an implement end goes through would move the implementer's story.
      dispatch = %{story_dispatch() | "kind" => "review"}
      run_dir = Path.join(ctx.config.runs_dir, "old-review-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "kind" => "review",
          "status" => "succeeded",
          "reached" => "implementing"
        })
      )

      log =
        capture_log(fn ->
          {pid, _ref} = start_accepting(ctx, %{}, [])
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          :ok =
            wait_until(
              fn ->
                match?({:ok, %{"terminal_reported" => "retired_kind"}}, RunState.read(run_dir))
              end,
              5_000
            )

          refute_receive {:test_loopctl, {:session_ended, _}}, 500
          refute_receive {:test_loopctl, {:stage, _}}, 100
        end)

      assert log =~ "this runner no longer runs review"
    end

    test "a restarted Control honours a claim end recorded beside a finished run", ctx do
      # A run that never got a worktree owes only its terminal `escalated`; the claim it ran under
      # was seen to end by a previous Control. Nothing of its work is sent, and the end is recorded
      # refused, so no later Control sends it either.
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "claim-ended-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "failed",
          "reached" => "claimed"
        })
      )

      :ok =
        LoopctlRunner.ClaimEnded.record(
          ctx.config.runs_dir,
          dispatch["dispatch_id"],
          3,
          "stage",
          "stale_claim_epoch"
        )

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream")
        :ok = wait_until(end_recorded(run_dir, "refused"), 5_000)
        refute_receive {:test_loopctl, {:stage, _}}, 800
        assert Control.info(pid).stage_reports_pending == 0
      end)
    end

    test "a restarted Control honours a claim end recorded beside a live run's directory", ctx do
      # The run outlived the Control that saw its claim end; its next message opens a stream here,
      # and that stream takes nothing of its work but the `session_ended`.
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "claim-ended-live")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing",
          "terminal_reported" => true
        })
      )

      :ok =
        LoopctlRunner.ClaimEnded.record(
          ctx.config.runs_dir,
          dispatch["dispatch_id"],
          3,
          "trace",
          "unknown_dispatch"
        )

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, session_stop_retry_ms: 100)
        binding = DispatchRun.binding(dispatch)
        send(pid, {:run_stage, binding, {:implementing, %{}}})
        send(pid, {:run_stage, binding, {:finished, escalated_summary()}})

        assert %{"reason" => "completed"} = next_session_ended()
        refute_receive {:test_loopctl, {:stage, _}}, 800
      end)
    end

    test "a trace batch refused as ending the claim stops the live run's session", ctx do
      # The refusal is scripted only once the session is running (its process group recorded):
      # scripted from the start it can land while the tree is still cut, and then the run reads
      # the claim's marker and starts no session at all — correct, and not what this test is
      # about. The batches carrying the session's own events are the ones refused.
      dispatch = story_dispatch()
      id = dispatch["dispatch_id"]
      assert "stale_claim_epoch" in Contract.claim_ending_errors("trace")

      session_running? = fn ->
        Enum.any?(RunState.all(ctx.config.runs_dir), fn {_dir, state} ->
          state["dispatch_id"] == id and is_integer(state["pgid"])
        end)
      end

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          # A real worktree is cut before the session: 60s under load.
          :ok = wait_until(session_running?, 60_000)
          TestLoopctl.put(:trace_replies, [{id, {:error, %{reason: "stale_claim_epoch"}}}])

          assert %{"reason" => "crashed", "dispatch_id" => ^id} = next_session_ended(60_000)
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, %{"to" => "escalated"}}}, 300
          GenServer.stop(pid)
        end)

      assert log =~
               "loopctl refused trace for dispatch #{id} " <>
                 "(stale_claim_epoch), which ends the claim it ran under"
    end

    test "a repeated accept refused as ending the claim stops the run already going under it",
         ctx do
      # The first accept is recorded and the run starts; the dispatch delivered again at the SAME
      # epoch is answered `accepted` again, and loopctl refusing THAT with a claim-ending code
      # (`claim_ending_errors.dispatch_reply`) means the claim the run holds is over.
      TestLoopctl.put(:dispatch_reply_replies, [:ok, {:error, %{reason: "unknown_dispatch"}}])
      assert "unknown_dispatch" in Contract.claim_ending_errors("dispatch_reply")
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "hang", %{}, session_stop_retry_ms: 100)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
          assert %{"to" => "worktree"} = next_stage()
          assert %{"to" => "implementing"} = next_stage()

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
          assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
          assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

          assert %{"reason" => "crashed"} = next_session_ended(20_000)
          runs_done(pid)
          GenServer.stop(pid)
        end)

      assert log =~ "(unknown_dispatch), which ends the claim it ran under"
    end

    test "a stale_stage naming a stage no transition leaves ends the run rather than retrying",
         ctx do
      # `permanent_error_conditions` calls stale_stage PERMANENT here: the story has reached a
      # stage no runner can report out of, which a session reaches by escalating through the HTTP
      # surface under the same claim while its run is still going. Retrying into it is what the
      # walk this replaced would do, for ever.
      dispatch = story_dispatch()
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage", stage: "escalated"}}])

      log =
        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream")
          binding = DispatchRun.binding(dispatch)

          send(pid, {:run_stage, binding, {:finished, escalated_summary()}})

          assert %{"from" => "implementing", "to" => "escalated"} = next_stage()
          # Nothing is tried from `escalated`, nor from anywhere else.
          refute_receive {:test_loopctl, {:stage, _}}, 1_000
          assert Control.info(pid).stage_reports_pending == 0
        end)

      assert log =~ "is at escalated, which no transition leaves"
      # The contract's own words for why, carried into the line an operator reads.
      assert log =~ "stage_transitions"
    end

    test "a stale_stage that names no stage is given up rather than guessed at", ctx do
      # A refusal with no row is one this runner cannot act on: 1.11.0 publishes `stage` on every
      # stale_stage refusal of a stage report, so a bare one means something upstream changed, and
      # guessing is what cost 2026-09-14 three refused attempts that could name nothing.
      dispatch = story_dispatch()
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage"}}])

      log =
        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream")
          binding = DispatchRun.binding(dispatch)

          send(pid, {:run_stage, binding, {:finished, escalated_summary()}})

          assert %{"from" => "implementing", "to" => "escalated"} = next_stage()
          refute_receive {:test_loopctl, {:stage, _}}, 1_000
          assert Control.info(pid).stage_reports_pending == 0
        end)

      assert log =~ "stale_stage naming no stage"
    end

    test "free disk is checked on the repo checkout's volume too", ctx do
      repo_path = Path.join(ctx.root, "repo")

      free_disk = fn
        ^repo_path -> {:ok, 5}
        _ -> {:ok, 50_000}
      end

      {_pid, topic} =
        accepting_control(ctx, "stream", %{min_free_disk_mb: 100}, free_disk: free_disk)

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert %{"decision" => "refused", "reason" => "insufficient_disk", "detail" => detail} =
               reply

      assert detail =~ "under #{repo_path}"
    end

    # --- US-48.16: a pr-mode session's pull request, read from the forge ---

    @head_sha "2fd0c5233b323ca4dc6e4d793536e884c902d8bd"
    @merge_sha "a1076b601b1651bc411b0822e1d89cc5550a03b4"

    defp forge_pr(dispatch, overrides) do
      Map.merge(
        %{
          "number" => 3938,
          "state" => "MERGED",
          "headRefName" => dispatch["branch"],
          "headRefOid" => @head_sha,
          "baseRefName" => dispatch["base_branch"],
          "isCrossRepository" => false,
          "mergeCommit" => %{"oid" => @merge_sha},
          "statusCheckRollup" => []
        },
        overrides
      )
    end

    # A forge that tells the test what it was asked and answers `answer`.
    defp forge_answering(answer) do
      test = self()

      fn repo, head, base, _timeout ->
        send(test, {:forge_asked, repo, head, base})
        answer
      end
    end

    defp observed_list(dispatch, overrides),
      do:
        LoopctlRunner.PrStages.observed(
          [forge_pr(dispatch, overrides)],
          dispatch["branch"],
          "master"
        )

    # Every message to the test, stage reports and session_ended, in arrival order, up to and
    # including the session_ended.
    defp reports_through_session_ended(acc \\ []) do
      receive do
        {:test_loopctl, {:stage, payload}} ->
          reports_through_session_ended([{:stage, payload["from"], payload["to"], payload} | acc])

        {:test_loopctl, {:session_ended, payload}} ->
          Enum.reverse([{:session_ended, payload["reason"]} | acc])
      after
        15_000 -> flunk("no session_ended; got #{inspect(Enum.reverse(acc))}")
      end
    end

    defp transitions(reports),
      do:
        Enum.map(reports, fn
          {:stage, from, to, _payload} -> {from, to}
          other -> other
        end)

    test "TC-48.16.1: a merged pull request is reported up to merged, then session_ended", ctx do
      dispatch = story_dispatch()

      {_pid, topic} =
        accepting_control(ctx, "stream", %{},
          forge: forge_answering({:ok, [forge_pr(dispatch, %{})]})
        )

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      reports = reports_through_session_ended()

      assert transitions(reports) == [
               {"claimed", "worktree"},
               {"worktree", "implementing"},
               {"implementing", "reviewing"},
               {"reviewing", "pr_open"},
               {"pr_open", "ci"},
               {"ci", "merged"},
               {:session_ended, "completed"}
             ]

      # Asked about THIS dispatch's repo, branch and base.
      assert_received {:forge_asked, "mkreyman/fixture", branch, "master"}
      assert branch == dispatch["branch"]

      effects = for {:stage, _, to, p} <- reports, into: %{}, do: {to, {p["edge"], p["effects"]}}
      assert effects["reviewing"] == {"forward", nil}
      assert effects["pr_open"] == {"forward", %{"pr_number" => 3938, "head_sha" => @head_sha}}
      assert effects["ci"] == {"forward", %{"head_sha" => @head_sha}}
      assert effects["merged"] == {"forward", %{"merge_sha" => @merge_sha}}
    end

    test "TC-48.16.2: an open pull request whose checks are not green stops at pr_open", ctx do
      dispatch = story_dispatch()
      open = forge_pr(dispatch, %{"state" => "OPEN", "mergeCommit" => nil})

      {_pid, topic} = accepting_control(ctx, "stream", %{}, forge: forge_answering({:ok, [open]}))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert transitions(reports_through_session_ended()) == [
               {"claimed", "worktree"},
               {"worktree", "implementing"},
               {"implementing", "reviewing"},
               {"reviewing", "pr_open"},
               {:session_ended, "completed"}
             ]
    end

    test "TC-48.16.2: an open pull request with green CI is reported through ci", ctx do
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      green = [%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      observed = observed_list(dispatch, %{"state" => "OPEN", "statusCheckRollup" => green})

      send(pid, {:run_stage, binding, {:implementing, %{}}})
      send(pid, {:run_stage, binding, {:observed, observed}})

      send(
        pid,
        {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
      )

      assert transitions(reports_through_session_ended()) == [
               {"worktree", "implementing"},
               {"implementing", "reviewing"},
               {"reviewing", "pr_open"},
               {"pr_open", "ci"},
               {:session_ended, "completed"}
             ]
    end

    test "TC-48.16.2: no pull request reports nothing beyond implementing", ctx do
      dispatch = story_dispatch()
      {_pid, topic} = accepting_control(ctx, "stream", %{}, forge: forge_answering({:ok, []}))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert transitions(reports_through_session_ended()) == [
               {"claimed", "worktree"},
               {"worktree", "implementing"},
               {:session_ended, "completed"}
             ]

      assert_received {:forge_asked, _, _, _}
    end

    test "a forge that fails reports nothing extra, and session_ended still goes", ctx do
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {_pid, topic} =
            accepting_control(ctx, "stream", %{},
              forge: forge_answering({:error, "gh exited 1: HTTP 502"})
            )

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert transitions(reports_through_session_ended()) == [
                   {"claimed", "worktree"},
                   {"worktree", "implementing"},
                   {:session_ended, "completed"}
                 ]
        end)

      assert log =~ "could not read the forge for mkreyman/fixture"
    end

    test "a thread-mode repository reports nothing new and asks no forge", ctx do
      # AC-48.16.5. A thread repository's prompt is refused before any session (contract 1.23.0
      # retired thread mode), so there is no session end to observe at all.
      File.write!(Path.join([ctx.root, "repo", ".loopctl", "mode"]), "thread\n")
      git!(Path.join(ctx.root, "repo"), ["commit", "-q", "-am", "thread"])
      dispatch = story_dispatch()

      {_pid, topic} =
        accepting_control(ctx, "stream", %{},
          forge: forge_answering({:ok, [forge_pr(dispatch, %{})]})
        )

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
      assert %{"from" => "worktree", "to" => "escalated"} = next_stage()
      refute_receive {:test_loopctl, {:stage, _}}, 500
      refute_received {:forge_asked, _, _, _}
    end

    test "a refused observed stage stops the sequence, logged, and session_ended goes", ctx do
      TestLoopctl.put(:stage_replies, [:ok, :ok, {:error, %{reason: "effect_conflict"}}])
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      log =
        capture_log(fn ->
          send(pid, {:run_stage, binding, {:implementing, %{}}})
          send(pid, {:run_stage, binding, {:observed, observed_list(dispatch, %{})}})

          send(
            pid,
            {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
          )

          assert transitions(reports_through_session_ended()) == [
                   {"worktree", "implementing"},
                   {"implementing", "reviewing"},
                   {"reviewing", "pr_open"},
                   {:session_ended, "completed"}
                 ]

          # Never retried, and nothing after it.
          refute_receive {:test_loopctl, {:stage, _}}, 500
        end)

      assert log =~ "loopctl refused the stage reviewing -> pr_open"
      assert log =~ "effect_conflict"
    end

    test "an observed stage given up after internal_error stops the sequence too", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:stage_replies, [:ok, internal, internal, internal])
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      capture_log(fn ->
        send(pid, {:run_stage, binding, {:implementing, %{}}})
        send(pid, {:run_stage, binding, {:observed, observed_list(dispatch, %{})}})

        send(
          pid,
          {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
        )

        assert transitions(reports_through_session_ended()) == [
                 {"worktree", "implementing"},
                 {"implementing", "reviewing"},
                 {"implementing", "reviewing"},
                 {"implementing", "reviewing"},
                 {:session_ended, "completed"}
               ]

        refute_receive {:test_loopctl, {:stage, _}}, 500
      end)
    end

    test "stages loopctl already holds are not re-sent: the rest go from the row's stage", ctx do
      # The session reported reviewing, pr_open and ci itself; loopctl's refusal names the row.
      TestLoopctl.put(:stage_replies, [:ok, {:error, %{reason: "stale_stage", stage: "ci"}}, :ok])
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      send(pid, {:run_stage, binding, {:implementing, %{}}})
      send(pid, {:run_stage, binding, {:observed, observed_list(dispatch, %{})}})

      send(
        pid,
        {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
      )

      reports = reports_through_session_ended()

      assert transitions(reports) == [
               {"worktree", "implementing"},
               {"implementing", "reviewing"},
               {"ci", "merged"},
               {:session_ended, "completed"}
             ]

      assert {:stage, "ci", "merged", %{"effects" => %{"merge_sha" => @merge_sha}}} =
               Enum.at(reports, 2)
    end

    test "a row already at merged takes none of the observed stages, and session_ended goes",
         ctx do
      TestLoopctl.put(:stage_replies, [:ok, {:error, %{reason: "stale_stage", stage: "merged"}}])
      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      send(pid, {:run_stage, binding, {:implementing, %{}}})
      send(pid, {:run_stage, binding, {:observed, observed_list(dispatch, %{})}})

      send(
        pid,
        {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
      )

      assert transitions(reports_through_session_ended()) == [
               {"worktree", "implementing"},
               {"implementing", "reviewing"},
               {:session_ended, "completed"}
             ]
    end

    test "a stale_stage naming a row BEHIND the observed stage stops the sequence", ctx do
      TestLoopctl.put(:stage_replies, [:ok, {:error, %{reason: "stale_stage", stage: "worktree"}}])

      {pid, _topic} = accepting_control(ctx, "stream")
      dispatch = story_dispatch()
      binding = DispatchRun.binding(dispatch)

      capture_log(fn ->
        send(pid, {:run_stage, binding, {:implementing, %{}}})
        send(pid, {:run_stage, binding, {:observed, observed_list(dispatch, %{})}})

        send(
          pid,
          {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
        )

        assert transitions(reports_through_session_ended()) == [
                 {"worktree", "implementing"},
                 {"implementing", "reviewing"},
                 {:session_ended, "completed"}
               ]
      end)
    end

    test "a fresh Control resends a finished run's observed stages from disk, then its end",
         ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "observed-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing",
          "observed_stages" => observed_list(dispatch, %{})
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")

      assert transitions(reports_through_session_ended()) == [
               {"implementing", "reviewing"},
               {"reviewing", "pr_open"},
               {"pr_open", "ci"},
               {"ci", "merged"},
               {:session_ended, "completed"}
             ]

      :ok = wait_until(end_recorded(run_dir, true))
    end

    test "a fresh Control's session_ended carries the turns and left-behind the run recorded",
         ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "counted-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "max_turns_exceeded",
          "reached" => "implementing",
          "turns_used" => 9,
          "work_left_behind" => true
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")

      assert next_session_ended(5_000) == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "reason" => "max_turns_exceeded",
               "turns_used" => 9,
               "work_left_behind" => true
             }
    end

    test "a fresh Control reports the end of a finished run loopctl never acknowledged", ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "unreported-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing"
        })
      )

      {pid, _topic} = accepting_control(ctx, "stream")

      assert next_session_ended(5_000) == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "reason" => "completed"
             }

      :ok = wait_until(end_recorded(run_dir, true))
      refute_received {:test_loopctl, {:stage, _}}

      # Recorded, so the next Control does not report it again.
      GenServer.stop(pid)
      {second, _ref} = start_accepting(ctx, %{}, [])
      :ok = wait_until(fn -> Control.info(second).joined end, 5_000)
      refute_receive {:test_loopctl, {:session_ended, _}}, 800
      refute_received {:test_loopctl, {:stage, _}}
    end

    test "a fresh Control reports an escalated run's escalation, then its session's end", ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "escalated-run")
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "escalations.ndjson"), ~s({"reason":"a business call"}\n))

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "escalated",
          "reached" => "implementing"
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")

      assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} =
               next_stage(5_000)

      assert reason =~ "the session escalated: a business call"
      assert %{"reason" => "completed"} = next_session_ended(5_000)
      :ok = wait_until(end_recorded(run_dir, true))
    end

    test "an escalation recorded does not record the run's end while its session_ended is not",
         ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:session_ended_replies, [internal, internal])
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "escalated-unsettled-run")
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "escalations.ndjson"), ~s({"reason":"a business call"}\n))

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "escalated",
          "reached" => "implementing"
        })
      )

      capture_log(fn ->
        {pid, _topic} = accepting_control(ctx, "stream", %{}, internal_error_attempts: 2)
        assert %{"to" => "escalated"} = next_stage(5_000)
        for _ <- 1..2, do: assert(%{"reason" => "completed"} = next_session_ended(5_000))
        :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)
      end)

      # The escalation was acknowledged, but the run's LAST end report was not: a restarted
      # Control must still send it.
      assert {:ok, state} = RunState.read(run_dir)
      refute Map.has_key?(state, "terminal_reported")
    end

    test "a run whose owner died after its session escalated is reported escalated, not crashed",
         ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "dead-owner-escalated-run")
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "escalations.ndjson"), ~s({"reason":"a business call"}\n))

      # "running", and no owner that is alive: the run never recorded its end.
      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "running"
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")

      assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} =
               next_stage(5_000)

      assert reason =~ "the session escalated: a business call"
      # `crashed` would release the claim over runner_lost and re-queue the story.
      assert %{"reason" => "completed"} = next_session_ended(5_000)
      :ok = wait_until(end_recorded(run_dir, true))
    end

    test "a run whose owner died with no escalation is still reported crashed", ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "dead-owner-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "running"
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")
      assert %{"reason" => "crashed"} = next_session_ended(5_000)
      refute_receive {:test_loopctl, {:stage, _}}, 300
    end

    test "a fresh Control reports a run over its wall clock with that reason", ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "wall-clock-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "wall_clock_exceeded",
          "reached" => "implementing"
        })
      )

      {_pid, _topic} = accepting_control(ctx, "stream")
      assert %{"reason" => "wall_clock_exceeded"} = next_session_ended(5_000)
      refute_receive {:test_loopctl, {:stage, _}}, 300
    end

    test "a session_ended whose reply is lost is resent as the same bytes after a rejoin", ctx do
      TestLoopctl.put(:session_ended_replies, [:none, :replayed])
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream")
          binding = DispatchRun.binding(story_dispatch())
          send(pid, {:run_stage, binding, {:finished, %{status: "succeeded"}}})

          first = next_session_ended(5_000)
          :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 1 end, 3_000)

          TestLoopctl.disconnect_runner()
          :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          assert next_session_ended(5_000) == first
          :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)
          refute_receive {:test_loopctl, {:session_ended, _}}, 500
        end)

      assert log =~ "it was a resend, and loopctl applied nothing a second time"
    end

    test "the session's end waits behind every stage report still to go", ctx do
      # Reported while the channel is down, both are held; after the rejoin the stage goes first,
      # because a `crashed` end releases the claim and a stage report sent after it is refused.
      {pid, _topic} = accepting_control(ctx, "stream")
      binding = DispatchRun.binding(story_dispatch())

      capture_log(fn ->
        TestLoopctl.disconnect_runner()
        :ok = wait_until(fn -> not Control.info(pid).joined end, 3_000)
        send(pid, {:run_stage, binding, {:implementing, %{}}})

        send(
          pid,
          {:run_stage, binding, {:finished, %{status: "failed", reached: "implementing"}}}
        )

        :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

        assert_receive {:test_loopctl, {event, _payload}} when event in [:stage, :session_ended],
                       5_000

        assert event == :stage
        assert %{"reason" => "crashed"} = next_session_ended(5_000)
      end)
    end

    test "a rate-limited session_ended waits the interval it names, then goes again", ctx do
      limited = {:error, %{reason: "rate_limited", min_interval_ms: 400}}
      TestLoopctl.put(:session_ended_replies, [limited, :ok])
      {pid, _topic} = accepting_control(ctx, "stream")
      binding = DispatchRun.binding(story_dispatch())
      send(pid, {:run_stage, binding, {:finished, %{status: "succeeded"}}})

      first = next_session_ended(5_000)
      sent = System.monotonic_time(:millisecond)
      assert next_session_ended(3_000) == first
      assert System.monotonic_time(:millisecond) - sent >= 400
      :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)
      refute_receive {:test_loopctl, {:session_ended, _}}, 500
    end

    test "a rate-limited session_ended whose interval is not a positive integer goes again",
         ctx do
      limited = {:error, %{reason: "rate_limited", min_interval_ms: "400"}}
      TestLoopctl.put(:session_ended_replies, [limited, :ok])
      {pid, _topic} = accepting_control(ctx, "stream")
      binding = DispatchRun.binding(story_dispatch())
      send(pid, {:run_stage, binding, {:finished, %{status: "succeeded"}}})

      first = next_session_ended(5_000)
      assert next_session_ended(3_000) == first
      :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)
    end

    test "internal_error on a session_ended is retried to the ceiling, left for a restart", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:session_ended_replies, [internal, internal, internal])
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "internal-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing"
        })
      )

      log =
        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream", %{}, internal_error_attempts: 3)
          for _ <- 1..3, do: assert(%{"reason" => "completed"} = next_session_ended(5_000))
          refute_receive {:test_loopctl, {:session_ended, _}}, 800
          assert Control.info(pid).session_ended_pending == 0
        end)

      assert log =~ ~r/giving up on session_ended for dispatch \S+ after 3 internal_error/
      # Only this process gave up: nothing is recorded, so the next Control sends it again.
      assert {:ok, state} = RunState.read(run_dir)
      refute Map.has_key?(state, "terminal_reported")
    end

    test "a permanent refusal of a session_ended is recorded and not sent again", ctx do
      for {refusal, recorded} <- [{"stale_claim_epoch", "refused"}, {"already_recorded", true}] do
        TestLoopctl.put(:session_ended_replies, [{:error, %{reason: refusal}}])
        dispatch = story_dispatch()
        run_dir = Path.join(ctx.config.runs_dir, "permanent-#{refusal}")
        File.mkdir_p!(run_dir)

        RunState.update(
          run_dir,
          Map.merge(DispatchRun.binding(dispatch), %{
            "run_id" => Session.uuid4(),
            "status" => "failed",
            "reached" => "implementing"
          })
        )

        capture_log(fn ->
          {pid, _topic} = accepting_control(ctx, "stream")
          assert %{"reason" => "crashed"} = next_session_ended(5_000)
          :ok = wait_until(end_recorded(run_dir, recorded))
          refute_receive {:test_loopctl, {:session_ended, _}}, 500
          GenServer.stop(pid)
        end)
      end
    end

    test "a terminal report refused from a stage already tried is recorded and not reported again",
         ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "refused-run")
      File.mkdir_p!(run_dir)

      # A run that never got a worktree: its terminal `escalated` is the whole of its end.
      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "failed",
          "reached" => "claimed"
        })
      )

      # The row is named as `worktree` twice. A stage already reported from is never reported from
      # again, which is what bounds the retries however the row moves underneath: without it, a
      # refusal that keeps naming one stage is an unbounded loop rather than a run that ends.
      stale = {:error, %{reason: "stale_stage", stage: "worktree"}}
      TestLoopctl.put(:stage_replies, [stale, stale])
      {pid, _topic} = accepting_control(ctx, "stream")

      refused? = fn ->
        match?({:ok, %{"terminal_reported" => "refused"}}, RunState.read(run_dir))
      end

      :ok = wait_until(refused?, 8_000)

      # A later Control would only be refused again: it reports nothing.
      GenServer.stop(pid)
      flush_stages()
      {second, _ref} = start_accepting(ctx, %{}, [])
      :ok = wait_until(fn -> Control.info(second).joined end, 5_000)
      refute_receive {:test_loopctl, {:stage, _}}, 800
    end

    test "a fresh Control resends a pending accept and starts the run on ok", ctx do
      test = self()
      dispatch = story_dispatch()
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)

      {pid, _topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert reply == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "decision" => "accepted"
             }

      assert_receive {:run_started, story_id}, 5_000
      assert story_id == DispatchRun.story_id(dispatch["story_id"])
      assert LoopctlRunner.PendingStarts.all(ctx.config.runs_dir) == []
      runs_done(pid)
    end

    test "a pending start resumed by a fresh Control keeps its deadline_at", ctx do
      # Contract 1.19.0's stop bound survives the restart: the pending file is the dispatch as it
      # arrived, and the story rebuilt from it carries the same instant. A start that dropped it
      # would give the resumed session its whole wall clock past the moment loopctl's lease sweep
      # may release the story.
      test = self()
      deadline = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      dispatch = story_dispatch(%{"deadline_at" => DateTime.to_iso8601(deadline)})
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)

      run = fn config, story, opts ->
        send(test, {:run_deadline, story.deadline_at})
        Run.execute(config, story, opts)
      end

      {pid, _topic} = accepting_control(ctx, "stream", %{}, run: run)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_deadline, ^deadline}, 5_000
      runs_done(pid)
    end

    test "a dispatch whose deadline_at leaves no time to stop a session is refused other", ctx do
      # A statement about a moment: loopctl places the story again. `kind_not_supported` would say
      # this runner never runs implement, which loopctl may keep for ever.
      {pid, topic} = accepting_control(ctx, "stream")
      # Still in the future, but inside the kill grace and the skew margin.
      deadline = DateTime.utc_now() |> DateTime.add(ctx.config.kill_grace_s, :second)
      dispatch = story_dispatch(%{"deadline_at" => DateTime.to_iso8601(deadline)})
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
      assert detail =~ ~r/^deadline_passed: /
      assert Control.info(pid).pending_starts == []
      assert Control.info(pid).runs_in_flight == []
    end

    test "a pending start past its deadline_at is dropped unresent, and a re-send runs", ctx do
      test = self()
      passed = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      dispatch = story_dispatch(%{"deadline_at" => passed})
      id = dispatch["dispatch_id"]
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)

      run = fn config, story, opts ->
        send(test, {:run_deadline, story.deadline_at})
        Run.execute(config, story, opts)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)

      # Dropped: its accept is not resent, its file is gone and nothing runs.
      refute_receive {:test_loopctl, {:dispatch_reply, %{"dispatch_id" => ^id}}}, 1_000
      assert LoopctlRunner.PendingStarts.all(ctx.config.runs_dir) == []
      refute_received {:run_deadline, _}

      # loopctl re-sends it with a later deadline (contract 1.19.0). The dropped start is
      # forgotten, so the re-send is decided afresh and RUNS, rather than being answered accepted
      # with nothing behind it.
      fresh = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      TestLoopctl.Endpoint.broadcast(
        topic,
        "dispatch",
        %{dispatch | "deadline_at" => DateTime.to_iso8601(fresh)}
      )

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_deadline, ^fresh}, 5_000
      runs_done(pid)
    end

    test "a re-send of a pending start with a later deadline_at moves it later, never earlier",
         ctx do
      # Neither accept is recorded, so the start stays pending across both re-sends.
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      test = self()

      run = fn config, story, opts ->
        send(test, {:run_deadline, story.deadline_at})
        Run.execute(config, story, opts)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)
      first = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      later = DateTime.add(first, 600, :second)
      dispatch = story_dispatch(%{"deadline_at" => DateTime.to_iso8601(first)})
      id = dispatch["dispatch_id"]

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", %{
        dispatch
        | "deadline_at" => DateTime.to_iso8601(later)
      })

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

      # On disk, where a restart reads it.
      assert [%{"dispatch_id" => ^id, "deadline_at" => on_disk}] =
               LoopctlRunner.PendingStarts.all(ctx.config.runs_dir)

      assert on_disk == DateTime.to_iso8601(later)

      # An EARLIER one does not move it back; this reply is recorded, and the run starts with the
      # later deadline held in memory.
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_deadline, ^later}, 5_000
      runs_done(pid)
    end

    test "a run that began past its deadline_at reports nothing, and records that", ctx do
      # Past by the time the run begins, though not when the dispatch was accepted: the run-start
      # guard. No `-> escalated` (a human is not needed) and no `session_ended` (there was none).
      past = DateTime.utc_now() |> DateTime.add(-60, :second)
      run = fn config, story, opts -> Run.execute(config, %{story | deadline_at: past}, opts) end
      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      runs_done(pid)

      refute_receive {:test_loopctl, {:stage, _}}, 1_000
      refute_receive {:test_loopctl, {:session_ended, _}}, 300

      assert [{_dir, %{"status" => "deadline_passed", "terminal_reported" => "skipped"}}] =
               RunState.all(ctx.config.runs_dir)
    end

    test "a run that ended deadline_passed is forgotten, so loopctl's re-send runs", ctx do
      # Left in started_dispatches, the re-send (contract 1.19.0: same dispatch, a later deadline)
      # is answered `accepted` while nothing runs, until the lease sweep takes the claim back.
      test = self()
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      run = fn config, story, opts ->
        send(test, :run_called)
        Run.execute(config, %{story | deadline_at: past}, opts)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive :run_called, 5_000
      runs_done(pid)

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      # Decided afresh: a run of its own, not an `accepted` with nothing behind it.
      assert_receive :run_called, 5_000
      runs_done(pid)
    end

    test "a re-send while the sessionless run is still ending is refused busy, then runs", ctx do
      # Forgotten the moment its end is reported, but its task is still in `runs`, keyed by the
      # dispatch: accepting over it would take that task's end for the new run's. Refused for the
      # moment instead — `other`, never `kind_not_supported` — and decided afresh once it is gone.
      test = self()
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      run = fn config, story, opts ->
        send(test, :run_called)
        result = Run.execute(config, %{story | deadline_at: past}, opts)
        # Its end is reported: `:finished` is in Control's mailbox before this is sent, and so
        # before any re-send the test makes after receiving it. The task lingers until released.
        send(test, {:run_ended, self()})

        receive do
          :release -> result
        end
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_ended, task}, 10_000
      assert_received :run_called

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert %{"decision" => "refused", "reason" => "other", "detail" => "busy: " <> _} = reply
      refute_received :run_called

      send(task, :release)
      runs_done(pid)

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_ended, second}, 10_000
      send(second, :release)
      runs_done(pid)
    end

    test "a pending start dropped for anything but its deadline is still answered accepted",
         ctx do
      # Only a start dropped for its deadline is forgotten. One this config no longer takes would be
      # refused again on every re-send, so its re-send is answered idempotently and starts nothing.
      test = self()
      dispatch = story_dispatch(%{"branch" => "not-a-loop-branch"})
      id = dispatch["dispatch_id"]
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)
      {pid, topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))

      refute_receive {:test_loopctl, {:dispatch_reply, %{"dispatch_id" => ^id}}}, 1_000
      assert LoopctlRunner.PendingStarts.all(ctx.config.runs_dir) == []

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      refute_receive {:run_started, _}, 500
      assert Control.info(pid).runs_in_flight == []
    end

    test "a pending start with no deadline_at takes the one its re-send carries", ctx do
      # Neither of the first two accepts is recorded, so the start stays pending across the re-send.
      TestLoopctl.put(:dispatch_reply_replies, [:none, :none])
      test = self()

      run = fn config, story, opts ->
        send(test, {:run_deadline, story.deadline_at})
        Run.execute(config, story, opts)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{}, run: run)
      dispatch = story_dispatch()
      id = dispatch["dispatch_id"]
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

      deadline = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      resent = Map.put(dispatch, "deadline_at", DateTime.to_iso8601(deadline))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", resent)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

      # On disk, where a restart reads it.
      expected = DateTime.to_iso8601(deadline)

      assert [%{"dispatch_id" => ^id, "deadline_at" => ^expected}] =
               LoopctlRunner.PendingStarts.all(ctx.config.runs_dir)

      # And in memory, where the start reads it: this reply is recorded, and the run starts.
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", resent)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_deadline, ^deadline}, 5_000
      runs_done(pid)
    end

    test "a pending start dropped for its deadline stays answered while a run on disk holds it",
         ctx do
      # The one reading of the runs at init: a run that STARTED for the dispatch keeps it counted,
      # so a re-send is answered `accepted` and starts nothing, however the pending start fared.
      test = self()
      passed = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      dispatch = story_dispatch(%{"deadline_at" => passed})
      run_dir = Path.join(ctx.config.runs_dir, "started-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing",
          "terminal_reported" => "ok"
        })
      )

      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)
      {pid, topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))

      fresh = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", %{dispatch | "deadline_at" => fresh})
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      refute_receive {:run_started, _}, 1_000
      assert %{pending_starts: [], runs_in_flight: []} = Control.info(pid)
    end

    test "a restart does not count a deadline_passed run as started", ctx do
      test = self()
      dispatch = story_dispatch()
      deadline_passed_run!(ctx, dispatch)
      {pid, topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))

      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_started, _story_id}, 5_000
      runs_done(pid)
    end

    test "nor as the start that keeps a dropped pending start's dispatch", ctx do
      # A pending start past its deadline is dropped and its dispatch forgotten unless a run on
      # disk STARTED for it; one that ended deadline_passed did not.
      test = self()
      passed = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      dispatch = story_dispatch(%{"deadline_at" => passed})
      deadline_passed_run!(ctx, dispatch)
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)
      {pid, topic} = accepting_control(ctx, "stream", %{}, run: counting_run(test))

      fresh = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", %{dispatch | "deadline_at" => fresh})
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000
      assert_receive {:run_started, _story_id}, 5_000
      runs_done(pid)
    end

    test "a restart finds nothing to report for a run that began past its deadline_at", ctx do
      # `DispatchRun.end_reports/1` is what recovery asks too: a state without its settled marker
      # (as an older build would leave it) is still reported with nothing.
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "deadline-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "deadline_passed",
          "reached" => "claimed"
        })
      )

      {pid, _topic} = accepting_control(ctx, "stream")

      refute_receive {:test_loopctl, {:stage, _}}, 1_000
      refute_receive {:test_loopctl, {:session_ended, _}}, 300
      assert Control.info(pid).stage_reports_pending == 0
    end

    test "a foreground run resumes NO pending start, and leaves it for the service daemon", ctx do
      # The HIGH from round 2, and the path that actually starts a session: recovery does not go
      # through DispatchPolicy at all (rebuild_work forces accepts_dispatches: true, because the
      # accept was already given), so the decide-path refusal does not reach it. A service daemon
      # dies holding a pending accept, someone runs `mix loopctl.serve` over the same runs_dir to
      # debug, and without this the run starts in their login shell.
      test = self()
      dispatch = story_dispatch()
      :ok = LoopctlRunner.PendingStarts.write(ctx.config.runs_dir, dispatch)

      marker = LoopctlRunner.Application.refuse_dispatches_var()

      overrides =
        try do
          System.put_env(marker, "1")
          LoopctlRunner.Application.foreground_overrides()
        after
          System.delete_env(marker)
        end

      {pid, _} = accepting_control(ctx, "stream", %{}, [run: counting_run(test)] ++ overrides)

      # No accept resent, and above all no run started: both are the defect, in that order.
      refute_receive {:test_loopctl, {:dispatch_reply, _}}, 1_500
      refute_receive {:run_started, _}, 100
      # Nothing is deleted either: the entry is work this process is not taking, and the service
      # daemon must still find it.
      assert [%{"dispatch_id" => id}] = LoopctlRunner.PendingStarts.all(ctx.config.runs_dir)
      assert id == dispatch["dispatch_id"]
      assert Control.info(pid).joined

      # AND IT MUST NOT CLAIM THE ID EITHER. loopctl redelivers the dispatch — that is the
      # designed-for case after a restart — and `handle_dispatch/2` consults started_dispatches
      # BEFORE the policy. Seeded from the pending files, this process would answer `accepted`
      # for a run it has already decided not to start: loopctl would record the story as
      # executing here, `start_pending/2` would pop nothing, and nothing would say so until the
      # claim lease expired. The refusal has to be honest end to end.
      topic = "runner:" <> TestLoopctl.get(:runner_id)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert reply["decision"] == "refused"
      assert reply["reason"] == "dispatches_disabled"
      refute_receive {:run_started, _}, 100

      # Still on disk afterwards: the service daemon is the one that resumes it.
      assert [%{"dispatch_id" => ^id}] = LoopctlRunner.PendingStarts.all(ctx.config.runs_dir)
    end

    test "a run's stage message reaches a Control that registers after it was sent" do
      name = :"late_control_#{System.unique_integer([:positive])}"
      test = self()

      spawn(fn ->
        Process.sleep(400)
        Process.register(self(), name)

        receive do
          message -> send(test, {:delivered, message})
        end
      end)

      message = {:run_stage, %{"dispatch_id" => "d"}, {:implementing, %{}}}
      assert Control.notify_control(name, message, poll_ms: 50, wait_ms: 5_000) == :ok
      assert_receive {:delivered, ^message}, 1_000
    end

    test "a dispatch without a story, or malformed, is refused as other", ctx do
      {pid, topic} = accepting_control(ctx, "stream")

      no_story = story_dispatch() |> Map.delete("story")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", no_story)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
      assert detail == "the dispatch carries no story"

      malformed = story_dispatch() |> put_in(["story", "title"], String.duplicate("a", 201))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", malformed)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      # Contract 1.5.0 bounds the story, so its validation names the field first.
      assert %{"reason" => "other", "detail" => detail} = reply
      assert detail =~ "story.title"

      # A kind that is not a string is malformed, not an undeclared capability.
      mistyped = story_dispatch(%{"kind" => 7})
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", mistyped)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      assert %{"reason" => "other", "detail" => detail} = reply
      assert detail =~ "RunnerDispatch.kind"

      refute_receive {:test_loopctl, {:stage, _}}, 500
      assert Control.info(pid).runs_in_flight == []
      assert RunState.all(ctx.config.runs_dir) == []
    end

    # Contract 1.23.0 retired `review`: its enum and `dispatchable_kinds` no longer name it, so a
    # review dispatch would fail validation as `other`. It is refused `kind_not_supported` instead,
    # as any kind this runner does not run is — a statement of capability, judged before the
    # message's shape, so loopctl never reads the refusal as a malformed message it might resend.
    test "a review dispatch, or any kind this runner does not run, is refused kind_not_supported",
         ctx do
      {pid, topic} = accepting_control(ctx, "stream")

      for kind <- ["review", "deploy"] do
        refute kind in LoopctlRunner.Control.kinds()
        dispatch = story_dispatch(%{"kind" => kind})
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
        assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

        assert %{
                 "dispatch_id" => id,
                 "decision" => "refused",
                 "reason" => "kind_not_supported",
                 "detail" =>
                   "this runner runs only: implement, triage, reply_draft, verify, spec_tune"
               } = reply

        assert id == dispatch["dispatch_id"]
        assert Contract.validate("RunnerDispatchReply", reply) == :ok
      end

      # And nothing the contract dispatches is undeclared.
      dispatchable = Contract.connection()["dispatchable_kinds"]
      assert Enum.sort(dispatchable) == Enum.sort(LoopctlRunner.Control.kinds())

      # No session started: no stage, no run directory, nothing in flight.
      refute_receive {:test_loopctl, {:stage, _}}, 500
      refute_receive {:test_loopctl, {:session_ended, _}}, 100
      assert Control.info(pid).runs_in_flight == []
      assert RunState.all(ctx.config.runs_dir) == []
      refute File.exists?(Path.join(ctx.fake, "argv"))
    end

    test "a dispatch arriving while one runs is refused at_capacity", ctx do
      # The run writes nothing for a second, so only the accept itself can count it.
      slow_run = fn config, story, opts ->
        Process.sleep(1_000)
        Run.execute(config, story, opts)
      end

      {pid, topic} = accepting_control(ctx, "stream", %{max_sessions: 1}, run: slow_run)
      first = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", first)
      assert_receive {:test_loopctl, {:dispatch_reply, %{"decision" => "accepted"}}}, 5_000

      second = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", second)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert %{"dispatch_id" => second_id, "decision" => "refused", "reason" => "at_capacity"} =
               reply

      assert second_id == second["dispatch_id"]
      runs_done(pid)
    end

    test "a repeated dispatch is answered again but never starts a second run", ctx do
      test = self()

      {pid, topic} = accepting_control(ctx, "stream", %{max_sessions: 2}, run: counting_run(test))
      dispatch = story_dispatch()
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

      assert_receive {:test_loopctl, {:dispatch_reply, first}}, 5_000
      assert_receive {:test_loopctl, {:dispatch_reply, ^first}}, 5_000
      assert first["decision"] == "accepted"

      assert_receive {:run_started, _}, 5_000
      runs_done(pid)
      refute_received {:run_started, _}
    end

    test "stale_stage on an intermediate report stops the intermediates, not the run's end",
         ctx do
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage", stage: "implementing"}}])
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "stream")
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
          # worktree -> implementing is not reported; the run's end is.
          assert %{"reason" => "completed"} = next_session_ended()
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 1_000
          assert Process.alive?(pid)
          assert Control.info(pid).stage_reports_pending == 0
        end)

      assert log =~
               "refused the stage claimed -> worktree for dispatch #{dispatch["dispatch_id"]}: " <>
                 "stale_stage"
    end

    test "a stale intermediate report re-aims the terminal one at the row it named", ctx do
      # The intermediates stop either way — they cannot follow a stage loopctl disagrees with — but
      # the row the refusal carries still applies to the TERMINAL report, which is built from
      # `stream.stage`. Left at the refused value it costs that report a guaranteed refused round
      # trip and an entry of a retry budget bounded by the transition table.
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage", stage: "reviewing"}}])
      dispatch = story_dispatch()

      capture_log(fn ->
        {pid, topic} = accepting_control(ctx, "escalate_and_exit")
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

        assert %{"from" => "claimed", "to" => "worktree"} = next_stage()

        # NOT "worktree", which is where this stream believed the story was and what the old code
        # would have sent: the refusal said `reviewing`, and the terminal report goes from there.
        assert %{"from" => "reviewing", "to" => "escalated", "reason" => reason} = next_stage()
        assert reason =~ "run ended escalated"
        runs_done(pid)
        refute_receive {:test_loopctl, {:stage, _}}, 1_000
        assert Control.info(pid).stage_reports_pending == 0
      end)
    end

    test "a report given up after internal_error blocks neither later reports nor the run's end",
         ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:stage_replies, [internal, internal, internal, :ok, :ok])

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "stream", %{}, internal_error_attempts: 3)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

          for _ <- 1..3, do: assert(%{"to" => "worktree"} = next_stage())
          # The stream is alive: the next intermediate report still goes, then the run's end.
          assert %{"from" => "worktree", "to" => "implementing"} = next_stage()
          assert %{"reason" => "completed"} = next_session_ended()
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 1_000
          assert Control.info(pid).stage_reports_pending == 0
        end)

      assert log =~
               ~r/giving up on the stage claimed -> worktree for dispatch \S+ after 3 internal_error.*moving on to the next report/
    end

    test "the terminal report gets the longer internal_error ceiling", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:stage_replies, [:ok, :ok, internal, internal, internal, internal])

      log =
        capture_log(fn ->
          {pid, topic} =
            accepting_control(ctx, "escalate_and_exit", %{},
              internal_error_attempts: 2,
              terminal_internal_error_attempts: 4
            )

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
          assert %{"to" => "worktree"} = next_stage()
          assert %{"to" => "implementing"} = next_stage()
          for _ <- 1..4, do: assert(%{"to" => "escalated"} = next_stage())
          # The session's end still goes behind the escalation given up.
          assert %{"reason" => "completed"} = next_session_ended()
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 1_500
          :ok = wait_until(fn -> Control.info(pid).session_ended_pending == 0 end, 3_000)

          # ...but the escalation was never recorded, so neither is the run's end: a restarted
          # Control reports both again.
          [{_run_dir, state}] = RunState.all(ctx.config.runs_dir)
          refute Map.has_key?(state, "terminal_reported")
        end)

      assert log =~
               ~r/giving up on the terminal stage implementing -> escalated for dispatch \S+ after 4/
    end

    test "internal_error on a dispatch_reply is resent up to the lower ceiling", ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:dispatch_reply_replies, [internal, internal, internal])

      log =
        capture_log(fn ->
          {_pid, topic} =
            accepting_control(ctx, "stream", %{accepts_dispatches: false},
              dispatch_reply_retry_ms: 50
            )

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

          for _ <- 1..3, do: assert_receive({:test_loopctl, {:dispatch_reply, _}}, 3_000)
          refute_receive {:test_loopctl, {:dispatch_reply, _}}, 800
        end)

      assert log =~ ~r/giving up on the dispatch_reply \(refused\) for dispatch \S+ after 3/
    end
  end

  describe "internal_error on a trace push" do
    test "is retried up to the lower ceiling, then given up for this session only", ctx do
      run_id = LoopctlRunner.Session.uuid4()
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:trace_replies, [internal, internal, internal])
      run_dir = Path.join(ctx.config.runs_dir, "ie-run")
      File.mkdir_p!(run_dir)

      LoopctlRunner.RunState.update(run_dir, %{
        "run_id" => run_id,
        "dispatch_id" => "2e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b",
        "claim_epoch" => 4,
        "status" => "succeeded"
      })

      File.write!(
        Path.join(run_dir, "trace.ndjson"),
        JSON.encode!(%{
          "run_id" => run_id,
          "seq" => 0,
          "event_id" => "0",
          "parent" => nil,
          "ts" => "2026-09-13T05:00:00Z",
          "type" => "run.started",
          "data" => %{}
        }) <> "\n"
      )

      log =
        capture_log(fn ->
          slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
          start_control(slow, trace_poll_ms: 100)

          for _ <- 1..3,
              do: assert_receive({:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 5_000)

          refute_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 800
        end)

      assert log =~ ~r/giving up on this run's batch trace pushes .* after 3 internal_error/
      # In memory only: a restart ships it again.
      refute File.exists?(Path.join(run_dir, "trace_ship.json"))
    end
  end

  defp collect_dispatch_replies(acc \\ []) do
    receive do
      {:test_loopctl, {:dispatch_reply, reply}} -> collect_dispatch_replies([reply | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_traces(run_id, n) do
    receive do
      {:test_loopctl, {:trace, %{"run_id" => ^run_id}}} -> count_traces(run_id, n + 1)
    after
      0 -> n
    end
  end

  defp flush_stages do
    receive do
      {:test_loopctl, {:stage, _}} -> flush_stages()
    after
      0 -> :ok
    end
  end

  defp flush_status do
    receive do
      {:test_loopctl, {:status, _}} -> flush_status()
    after
      0 -> :ok
    end
  end

  test "a dispatch push is refused without disturbing the connection", ctx do
    {pid, _ref} = start_control(ctx.config)
    runner_id = TestLoopctl.get(:runner_id)
    assert_receive {:test_loopctl, {:join, _, _}}, 5_000
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

    TestLoopctl.Endpoint.broadcast("runner:" <> runner_id, "dispatch", %{"dispatch_id" => "x"})
    assert_receive {:test_loopctl, {:status, _}}, 5_000
    assert Control.info(pid).joined
  end

  test "an unreadable token file is retried, and a fix within the retries connects", ctx do
    File.chmod!(ctx.token_file, 0o644)
    {pid, _ref} = start_control(ctx.config)

    :ok = wait_until(fn -> Control.info(pid).last_refusal == "token_unreadable" end, 3_000)
    refute_received {:test_loopctl, {:connect, _}}

    File.chmod!(ctx.token_file, 0o600)
    assert_receive {:test_loopctl, {:join, _, _}}, 10_000
    refute_receive {:fatal, _}, 100
  end

  test "a token file that stays unreadable is fatal, not an active service with no connection",
       ctx do
    File.rm!(ctx.token_file)
    {pid, ref} = start_control(ctx.config)

    assert_receive {:fatal, {:token_unreadable, reason}}, 15_000
    assert reason =~ "cannot read token file"
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:token_unreadable, _}}}, 2_000
    refute_received {:test_loopctl, {:connect, _}}
  end

  test "draining is reported at once", ctx do
    # A long interval, so only the immediate report can deliver it within the wait.
    slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
    {pid, _ref} = start_control(slow)
    assert_receive {:test_loopctl, {:join, _, _}}, 5_000
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

    Control.set_draining(pid, true)
    assert_receive {:test_loopctl, {:status, %{"draining" => true}}}, 3_000
  end

  test "a status refused as rate-limited is resent once the floor has passed", ctx do
    slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
    {pid, _ref} = start_control(slow)
    assert_receive {:test_loopctl, {:join, _, _}}, 5_000
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

    Control.set_draining(pid, true)
    assert_receive {:test_loopctl, {:status, _}}, 3_000
    Control.set_draining(pid, false)
    assert_receive {:test_loopctl, {:status_rate_limited, _}}, 3_000
    assert_receive {:test_loopctl, {:status, _}}, 3_000
  end

  test "a rate-limited status whose interval is not a positive integer waits the floor instead",
       ctx do
    # loopctl's data: a string here would crash Process.send_after/3, and this process with it.
    TestLoopctl.put(:status_min_interval_ms, "soon")
    slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
    {pid, _ref} = start_control(slow)
    assert_receive {:test_loopctl, {:join, _, _}}, 5_000
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

    Control.set_draining(pid, true)
    assert_receive {:test_loopctl, {:status, _}}, 3_000
    Control.set_draining(pid, false)
    assert_receive {:test_loopctl, {:status_rate_limited, _}}, 3_000
    assert_receive {:test_loopctl, {:status, _}}, 3_000
    assert Process.alive?(pid)
  end

  test "the runner reports draining while it cannot accept dispatches", ctx do
    {pid, _ref} = start_control(ctx.config)
    assert_receive {:test_loopctl, {:join, _, %{"draining" => true}}}, 5_000
    # info/1 shows what loopctl was told, not the unset set_draining flag.
    assert %{draining: true, accepts_dispatches: false} = Control.info(pid)
  end

  test "once dispatches are accepted, the set_draining value is what loopctl sees", ctx do
    slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}
    {pid, _ref} = start_control(slow, accepts_dispatches: true)
    assert_receive {:test_loopctl, {:join, _, %{"draining" => false}}}, 5_000
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

    Control.set_draining(pid, true)
    assert_receive {:test_loopctl, {:status, %{"draining" => true}}}, 3_000
    # Past loopctl's 1s floor, back to accepting: false must reach it too.
    Process.sleep(1_100)
    Control.set_draining(pid, false)
    assert_receive {:test_loopctl, {:status, %{"draining" => false}}}, 3_000
  end

  describe "what the log says when something goes wrong" do
    # The suite logs at :warning; the rejoin line is :info.
    setup do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)
    end

    test "a disconnect names the next attempt, and the rejoin says how long the outage lasted",
         ctx do
      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          first_join = Control.info(pid).joined_at

          TestLoopctl.disconnect_runner()
          :ok = wait_until(fn -> not Control.info(pid).joined end, 5_000)
          assert Control.info(pid).last_disconnect =~ "closed"

          :ok = wait_until(fn -> Control.info(pid).joined end, 10_000)
          assert Control.info(pid).joined_at >= first_join
        end)

      assert log =~ ~r/socket disconnected: .+; reconnect attempt 1 in \d+ms/
      assert log =~ ~r/joined runner:\S+ after \d+\.\ds out of the pool \(1 reconnect attempts\)/
    end

    test "a slow status reply is logged with its round trip", ctx do
      TestLoopctl.put(:status_reply, {:delay, 700})

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config, slow_reply_ms: 500)
          :ok = wait_until(fn -> is_integer(Control.info(pid).last_status_rtt_ms) end, 10_000)
          assert Control.info(pid).last_status_rtt_ms >= 700
          assert is_binary(Control.info(pid).last_status_acked_at)
        end)

      assert log =~ ~r/answered a status push after \d+ms; the link is slow/
    end

    test "a status push that is never answered is logged at the next tick", ctx do
      TestLoopctl.put(:status_reply, :none)

      log =
        capture_log(fn ->
          {_pid, _ref} = start_control(ctx.config, slow_reply_ms: 500)
          assert_receive {:test_loopctl, {:status, _}}, 5_000
          assert_receive {:test_loopctl, {:status, _}}, 5_000
          Process.sleep(100)
        end)

      assert log =~ "has not answered the status push sent"
      assert log =~ "(last answered never)"
    end

    test "a reply slower than the status interval is still measured, not called unanswered",
         ctx do
      TestLoopctl.put(:status_reply, {:delay, 1_500})

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config, slow_reply_ms: 1_000)
          :ok = wait_until(fn -> is_binary(Control.info(pid).last_status_acked_at) end, 10_000)
          assert Control.info(pid).last_status_rtt_ms >= 1_500
        end)

      assert log =~ ~r/answered a status push after \d+ms; the link is slow/
    end

    test "a push sent while an earlier one was pending stays watched after that one settles",
         ctx do
      # The first reply is late, and every reply after it never comes.
      TestLoopctl.put(:status_reply, [{:delay, 1_200}, :none])

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config, slow_reply_ms: 500)
          :ok = wait_until(fn -> is_binary(Control.info(pid).last_status_acked_at) end, 10_000)
          # The second push went out before the first reply landed and is still unanswered.
          assert Control.info(pid).status_push_pending
          Process.sleep(1_500)
        end)

      assert log =~ ~r/has not answered the status push sent \d+ms ago \(last answered 20/
    end

    test "an ok reply carrying a body counts as answered", ctx do
      TestLoopctl.put(:status_reply, {:body, %{next_interval_ms: 1_000}})

      capture_log(fn ->
        {pid, _ref} = start_control(ctx.config)
        :ok = wait_until(fn -> is_binary(Control.info(pid).last_status_acked_at) end, 5_000)
        refute Control.info(pid).status_push_pending
      end)
    end

    test "a status sent at once while the last push is in flight is not a slow link", ctx do
      TestLoopctl.put(:status_reply, {:delay, 300})
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(slow)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          Control.set_draining(pid, true)
          assert_receive {:test_loopctl, {:status, _}}, 3_000
          Control.set_draining(pid, false)
          :ok = wait_until(fn -> is_binary(Control.info(pid).last_status_acked_at) end, 5_000)
        end)

      refute log =~ "has not answered the status push"
    end

    test "an event this build does not handle is logged once, not on every repeat", ctx do
      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          topic = "runner:" <> TestLoopctl.get(:runner_id)

          for _ <- 1..3, do: TestLoopctl.Endpoint.broadcast(topic, "trace_cursor", %{"seq" => 1})

          assert_receive {:test_loopctl, {:status, _}}, 5_000
          assert Control.info(pid).joined
        end)

      assert length(String.split(log, ~s(loopctl sent "trace_cursor"))) == 2
    end

    test "an unreadable health metric is logged once when it fails and once when it recovers",
         ctx do
      {:ok, readings} =
        Agent.start_link(fn -> [{:error, "free_disk_mb"}, {:error, "free_disk_mb"}] end)

      measure = fn path, last ->
        Agent.get_and_update(readings, fn
          [reading | rest] -> {reading, rest}
          [] -> {LoopctlRunner.Health.measure(path, last), []}
        end)
      end

      # A long interval, so each status below is the one set_draining sends at once.
      slow = %{ctx.config | control: %{ctx.config.control | status_interval_s: 30}}

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(slow, measure: measure)
          assert_receive {:test_loopctl, {:join, _, join}}, 5_000
          refute Map.has_key?(join, "sample")
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
          # Recorded by the join itself, before any status has been sent.
          assert Control.info(pid).sample_error == "free_disk_mb"

          Control.set_draining(pid, true)
          assert_receive {:test_loopctl, {:status, status}}, 3_000
          refute Map.has_key?(status, "sample")

          Process.sleep(1_100)
          Control.set_draining(pid, false)
          assert_receive {:test_loopctl, {:status, %{"sample" => _}}}, 3_000
          assert Control.info(pid).sample_error == nil
        end)

      assert length(String.split(log, "health sample omitted: cannot read free_disk_mb")) == 2
      assert log =~ "health sample readable again"
    end

    test "every line carries the runner id, and a dispatch line its story and epoch", ctx do
      runner_id = TestLoopctl.get(:runner_id)

      log =
        capture_log([metadata: [:runner_id, :dispatch_id, :story_id, :claim_epoch]], fn ->
          {pid, _ref} = start_control(ctx.config)
          :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)

          dispatch = %{"dispatch_id" => "d-1", "story_id" => "s-1", "claim_epoch" => 4}
          TestLoopctl.Endpoint.broadcast("runner:" <> runner_id, "dispatch", dispatch)
          assert_receive {:test_loopctl, {:status, _}}, 5_000
        end)

      # The fake server's own Phoenix lines (CONNECTED TO, JOINED) are not the runner's.
      lines =
        log
        |> String.split("\n", trim: true)
        |> Enum.filter(&(&1 =~ ~r/\[(info|warning|error)\]/))
        |> Enum.reject(&(&1 =~ ~r/\] (CONNECTED TO|JOINED) /))

      assert lines != []
      assert Enum.all?(lines, &(&1 =~ "runner_id=#{runner_id}"))
      assert log =~ ~r/dispatch_id=d-1 story_id=s-1 claim_epoch=4 .*malformed dispatch received/
    end

    test "a refused upgrade logs its HTTP status, not the response headers", ctx do
      File.write!(ctx.token_file, "lc_wrong_token")

      log =
        capture_log(fn ->
          {pid, _ref} = start_control(ctx.config)
          :ok = wait_until(fn -> Control.info(pid).connect_attempts >= 1 end, 5_000)
          Process.sleep(100)
        end)

      assert log =~ "upgrade refused with HTTP 403; reconnect attempt 1 in 1000ms"
      refute log =~ "resp_headers"
    end
  end
end
