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
    assert join["contract_version"] == "1.0.0"
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
    {_pid, _ref} = start_control(ctx.config)
    assert_receive {:test_loopctl, {:join, _, %{"draining" => true}}}, 5_000
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
      assert log =~ ~r/dispatch_id=d-1 story_id=s-1 claim_epoch=4 .*malformed dispatch ignored/
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
