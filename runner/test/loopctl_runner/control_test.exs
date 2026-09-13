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
    {:ok, pid} = GenServer.start(Control, opts)
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
    assert join["contract_version"] == "1.2.0"
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
               "reason" => "dispatches_disabled"
             }

      assert Control.info(pid).joined
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
