defmodule LoopctlRunner.ControlTest do
  # One shared test server and its script: these run serially.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Contract, Control, ControlConfig, TestLoopctl}
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
end
