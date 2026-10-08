defmodule LoopctlWeb.RunnerShutdownNoticeTest do
  @moduledoc """
  Issue #815: draining the runner socket tells every connected runner `server_shutdown`
  before the drain closes it (`LoopctlWeb.RunnerShutdownNotice`). The rest of what the runner
  control plane records about itself is in `LoopctlWeb.RunnerObservabilityTest`, async.

  ## Why `async: false`

  The SUBJECT is a node-wide notice: the drain handler is attached once for the VM and turns
  the `[:phoenix, :socket_drain]` event into a broadcast on `Loopctl.Runners.shutdown_topic/0`,
  which every runner channel on the node subscribes to. That fan-out to every runner is the
  behaviour under test, so it reaches every runner channel any concurrently running test has
  joined, pushing `disconnecting` into those tests' mailboxes. ExUnit runs this module alone.
  """

  use LoopctlWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Loopctl.ApiSpec.RunnerContract
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @reply_timeout 2_000

  defp joined_runner do
    {raw, runner} = fixture(:runner, %{name: "minis"})

    {:ok, socket} =
      connect(RunnerSocket, %{},
        connect_info: %{
          x_headers: [{RunnerSocket.token_header(), raw}],
          peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
        }
      )

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, %{
        "contract_version" => RunnerContract.version(),
        "machine" => "minis",
        "cores" => 16,
        "memory_mb" => 28_000,
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false
      })

    _ = :sys.get_state(channel.channel_pid)
    %{runner: runner, channel: channel}
  end

  test "draining the runner socket tells every runner server_shutdown" do
    %{runner: runner, channel: channel} = joined_runner()

    log =
      capture_log([level: :info], fn ->
        :telemetry.execute(
          [:phoenix, :socket_drain],
          %{count: 1, total: 1, index: 1, rounds: 1},
          %{endpoint: @endpoint, socket: RunnerSocket, interval: 1_000, log: :info}
        )

        assert_push "disconnecting", %{reason: "server_shutdown"}, @reply_timeout
      end)

    assert Process.alive?(channel.channel_pid)
    assert log =~ "runner socket draining"
    assert log =~ "runner disconnecting: reason=server_shutdown runner_id=#{runner.id}"
  end
end
