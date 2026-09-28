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
    opts = Keyword.merge([config: config, on_fatal: &send(test, {:fatal, &1})], opts)

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
    assert join["contract_version"] == "1.12.0"
    # Declared on EVERY join, from the same list the kind check reads.
    assert join["kinds"] == LoopctlRunner.Control.kinds()
    assert join["kinds"] == ["implement"]
    # Non-empty ON THE WIRE, which is where it decides anything: loopctl reads an empty array as
    # no declaration at all and falls back to its permanent ledger.
    refute join["kinds"] == []
    assert join["repos"] == ["mkreyman/home_care_billing"]
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
      Map.merge(LoopctlRunner.Owner.current(), %{"run_id" => "live-run", "status" => "running"})
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

    test "under a service manager the config decides, and nothing overrides it", ctx do
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
          Map.merge(LoopctlRunner.Owner.current(), %{"status" => "running"})
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

    test "a rate-limited batch is resent, not skipped", ctx do
      run_id = ctx.run_id
      TestLoopctl.put(:trace_replies, [{:error, %{reason: "rate_limited", min_interval_ms: 50}}])
      run_dir = dispatched_run(ctx, 0..2)
      shipping_control(ctx)

      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => events}}}, 5_000
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id, "events" => ^events}}}, 3_000
      :ok = wait_until(fn -> File.exists?(Path.join(run_dir, "trace_ship.json")) end, 3_000)
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
          Map.merge(LoopctlRunner.Owner.current(), %{"status" => "running"})
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
          Map.merge(LoopctlRunner.Owner.current(), %{"status" => "running"})
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
      git_repo!(Path.join(ctx.root, "repo"))
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

      assert next_stage() == %{
               "dispatch_id" => id,
               "claim_epoch" => 3,
               "from" => "implementing",
               "to" => "escalated",
               "edge" => "session_escalated",
               "reason" => DispatchRun.finished_reason()
             }

      # The run's state is bound to the dispatch, so its trace ships.
      assert [{_run_dir, state}] = RunState.all(ctx.config.runs_dir)
      assert %{"dispatch_id" => ^id, "claim_epoch" => 3, "status" => "succeeded"} = state
      assert state["story_id"] == dispatch["story_id"]
      run_id = state["run_id"]
      assert_receive {:test_loopctl, {:trace, %{"run_id" => ^run_id}}}, 10_000

      # The session got the fenced story, and the runner's allowed tools only.
      argv = File.read!(Path.join(ctx.fake, "argv"))

      assert argv =~
               "<<<UNTRUSTED story.title>>>\nAdd a greeting\n<<<END UNTRUSTED story.title>>>"

      runs_done(pid)
      refute_receive {:test_loopctl, {:stage, _}}, 300
      :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
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

      assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} =
               next_stage(5_000)

      assert reason == DispatchRun.finished_reason()
      :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
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
      assert %{"to" => "escalated", "reason" => reason} = next_stage()
      assert reason == DispatchRun.finished_reason()
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

      send(
        pid,
        {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
      )

      assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} = next_stage()

      assert next_stage() == %{
               "dispatch_id" => binding["dispatch_id"],
               "claim_epoch" => 3,
               "from" => "claimed",
               "to" => "escalated",
               "edge" => "session_escalated",
               "reason" => reason
             }

      assert reason == DispatchRun.finished_reason()
      refute_receive {:test_loopctl, {:stage, _}}, 800
      assert Control.info(pid).stage_reports_pending == 0
    end

    test "a stream Control started itself retries its terminal report where the row says", ctx do
      stale = {:error, %{reason: "stale_stage", stage: "claimed"}}
      TestLoopctl.put(:stage_replies, [:ok, :ok, stale, :ok])

      capture_log(fn ->
        {pid, topic} = accepting_control(ctx, "stream")
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

        assert %{"to" => "worktree"} = next_stage()
        assert %{"to" => "implementing"} = next_stage()
        assert %{"from" => "implementing", "to" => "escalated"} = next_stage()
        assert %{"from" => "claimed", "to" => "escalated", "reason" => reason} = next_stage()
        assert reason == DispatchRun.finished_reason()
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

        send(
          pid,
          {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
        )

        assert %{"from" => "implementing", "to" => "escalated"} = next_stage(5_000)
        assert %{"from" => "worktree", "to" => "escalated"} = next_stage(5_000)

        assert %{"from" => "reviewing", "to" => "escalated", "reason" => reason} =
                 next_stage(5_000)

        assert reason == DispatchRun.finished_reason()
        refute_receive {:test_loopctl, {:stage, _}}, 800
        :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)
      end)
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

          send(
            pid,
            {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
          )

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

          send(
            pid,
            {:run_stage, binding, {:finished, %{status: "succeeded", reached: "implementing"}}}
          )

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

      assert next_stage(5_000) == %{
               "dispatch_id" => dispatch["dispatch_id"],
               "claim_epoch" => 3,
               "from" => "implementing",
               "to" => "escalated",
               "edge" => "session_escalated",
               "reason" => DispatchRun.finished_reason()
             }

      :ok = wait_until(fn -> Control.info(pid).stage_reports_pending == 0 end, 3_000)

      reported? = fn -> match?({:ok, %{"terminal_reported" => true}}, RunState.read(run_dir)) end
      :ok = wait_until(reported?)

      # Recorded, so the next Control does not report it again.
      GenServer.stop(pid)
      {second, _ref} = start_accepting(ctx, %{}, [])
      :ok = wait_until(fn -> Control.info(second).joined end, 5_000)
      refute_receive {:test_loopctl, {:stage, _}}, 800
    end

    test "a terminal report refused from a stage already tried is recorded and not reported again",
         ctx do
      dispatch = story_dispatch()
      run_dir = Path.join(ctx.config.runs_dir, "refused-run")
      File.mkdir_p!(run_dir)

      RunState.update(
        run_dir,
        Map.merge(DispatchRun.binding(dispatch), %{
          "run_id" => Session.uuid4(),
          "status" => "succeeded",
          "reached" => "implementing"
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

    test "a dispatch without a story is refused as other, a triage one as kind_not_supported",
         ctx do
      {pid, topic} = accepting_control(ctx, "stream")

      no_story = story_dispatch() |> Map.delete("story")
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", no_story)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert %{"decision" => "refused", "reason" => "other", "detail" => detail} = reply
      assert detail == "the dispatch carries no story"

      triage = story_dispatch(%{"kind" => "triage"})
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", triage)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000

      assert %{"decision" => "refused", "reason" => "kind_not_supported", "detail" => detail} =
               reply

      # The refusal names the declaration, from the same list the join sends.
      assert detail == "this runner runs only: implement"
      assert detail =~ Enum.join(LoopctlRunner.Control.kinds(), ", ")

      # The kind is judged before policy, so a draining runner still answers kind_not_supported
      # rather than draining: the reason states a capability, not a moment.
      Control.set_draining(pid, true)
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch(%{"kind" => "triage"}))

      assert_receive {:test_loopctl, {:dispatch_reply, %{"reason" => "kind_not_supported"}}},
                     5_000

      Control.set_draining(pid, false)

      malformed = story_dispatch() |> put_in(["story", "title"], String.duplicate("a", 201))
      TestLoopctl.Endpoint.broadcast(topic, "dispatch", malformed)
      assert_receive {:test_loopctl, {:dispatch_reply, reply}}, 5_000
      # Contract 1.5.0 bounds the story, so its validation names the field first.
      assert %{"reason" => "other", "detail" => detail} = reply
      assert detail =~ "story.title"

      refute_receive {:test_loopctl, {:stage, _}}, 500
      assert Control.info(pid).runs_in_flight == []
      assert RunState.all(ctx.config.runs_dir) == []
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

    test "stale_stage on an intermediate report stops the intermediates, not the terminal", ctx do
      TestLoopctl.put(:stage_replies, [{:error, %{reason: "stale_stage", stage: "implementing"}}])
      dispatch = story_dispatch()

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "stream")
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

          assert %{"from" => "claimed", "to" => "worktree"} = next_stage()
          # worktree -> implementing is not reported; the run's end is, from the believed stage.
          assert %{"to" => "escalated", "reason" => reason} = next_stage()
          assert reason == DispatchRun.finished_reason()
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
        {pid, topic} = accepting_control(ctx, "stream")
        TestLoopctl.Endpoint.broadcast(topic, "dispatch", dispatch)

        assert %{"from" => "claimed", "to" => "worktree"} = next_stage()

        # NOT "worktree", which is where this stream believed the story was and what the old code
        # would have sent: the refusal said `reviewing`, and the terminal report goes from there.
        assert %{"from" => "reviewing", "to" => "escalated", "reason" => reason} = next_stage()
        assert reason == DispatchRun.finished_reason()
        runs_done(pid)
        refute_receive {:test_loopctl, {:stage, _}}, 1_000
        assert Control.info(pid).stage_reports_pending == 0
      end)
    end

    test "a report given up after internal_error blocks neither later reports nor the terminal",
         ctx do
      internal = {:error, %{reason: "internal_error"}}
      TestLoopctl.put(:stage_replies, [internal, internal, internal, :ok, :ok])

      log =
        capture_log(fn ->
          {pid, topic} = accepting_control(ctx, "stream", %{}, internal_error_attempts: 3)
          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())

          for _ <- 1..3, do: assert(%{"to" => "worktree"} = next_stage())
          # The stream is alive: the next intermediate report still goes, then the terminal.
          assert %{"from" => "worktree", "to" => "implementing"} = next_stage()

          assert %{"from" => "implementing", "to" => "escalated", "reason" => reason} =
                   next_stage()

          assert reason == DispatchRun.finished_reason()
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
            accepting_control(ctx, "stream", %{},
              internal_error_attempts: 2,
              terminal_internal_error_attempts: 4
            )

          TestLoopctl.Endpoint.broadcast(topic, "dispatch", story_dispatch())
          assert %{"to" => "worktree"} = next_stage()
          assert %{"to" => "implementing"} = next_stage()
          for _ <- 1..4, do: assert(%{"to" => "escalated"} = next_stage())
          runs_done(pid)
          refute_receive {:test_loopctl, {:stage, _}}, 1_500
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
