defmodule LoopctlWeb.RunnerShutdownNoticeTest do
  @moduledoc """
  Issue #815: draining the runner socket tells every connected runner `server_shutdown`
  before the drain closes it (`LoopctlWeb.RunnerShutdownNotice`).

  The notice is a node-wide broadcast, so these tests never fire the real drain: each link of
  the chain is checked on its own. The handler is called with this test's own topic, the
  handler the application attached is read for the topic it broadcasts on, the runner channel
  is checked to be subscribed to that topic, and the channel is sent the message the broadcast
  delivers. Nothing here reaches another test's runner, so the module runs async.
  """

  use LoopctlWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.Runners
  alias LoopctlWeb.RunnerShutdownNotice
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @drain_measurements %{count: 1, total: 1, index: 1, rounds: 1}

  defp drain_metadata(socket),
    do: %{endpoint: @endpoint, socket: socket, interval: 1_000, log: :info}

  defp own_config do
    topic = "runner_shutdown_test:#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Loopctl.PubSub, topic)
    %{topic: topic, grace_ms: 0}
  end

  defp joined_runner do
    {raw, runner} = fixture(:runner, %{name: "minis"})
    {:ok, socket} = connect_runner_socket(raw)

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, runner_join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)
    %{runner: runner, channel: channel}
  end

  test "draining the runner socket broadcasts server_shutdown on the configured topic" do
    config = own_config()

    log =
      capture_log([level: :info], fn ->
        RunnerShutdownNotice.handle_event(
          [:phoenix, :socket_drain],
          @drain_measurements,
          drain_metadata(RunnerSocket),
          config
        )
      end)

    assert_receive :server_shutdown
    assert log =~ "runner socket draining"
  end

  test "draining another socket broadcasts nothing" do
    config = own_config()

    RunnerShutdownNotice.handle_event(
      [:phoenix, :socket_drain],
      @drain_measurements,
      drain_metadata(Phoenix.LiveView.Socket),
      config
    )

    refute_receive :server_shutdown, 200
  end

  test "the application's handler broadcasts on the topic runner channels subscribe to" do
    assert [handler] =
             Enum.filter(
               :telemetry.list_handlers([:phoenix, :socket_drain]),
               &(&1.id == RunnerShutdownNotice.handler_id())
             )

    assert handler.config == RunnerShutdownNotice.default_config()
    assert handler.config.topic == Runners.shutdown_topic()
    assert handler.config.grace_ms == RunnerShutdownNotice.grace_ms()
  end

  test "a joined runner channel is subscribed to the shutdown topic and tells its runner" do
    %{runner: runner, channel: channel} = joined_runner()

    assert channel.channel_pid in Enum.map(
             Registry.lookup(Loopctl.PubSub, Runners.shutdown_topic()),
             &elem(&1, 0)
           )

    log =
      capture_log([level: :info], fn ->
        send(channel.channel_pid, :server_shutdown)
        assert_push "disconnecting", %{reason: "server_shutdown"}, reply_timeout()
      end)

    assert Process.alive?(channel.channel_pid)
    assert log =~ "runner disconnecting: reason=server_shutdown runner_id=#{runner.id}"
  end
end
