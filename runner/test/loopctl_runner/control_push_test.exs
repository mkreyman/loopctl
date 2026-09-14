defmodule LoopctlRunner.ControlPushTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LoopctlRunner.Control
  alias Slipstream.Socket
  alias Slipstream.Socket.Join

  @topic "runner:3781bee6-2b97-4df0-9664-7f01a492630f"

  # A joined socket whose connection process takes the push's call and then does `then`.
  defp joined_socket(then) do
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _command} -> then.()
        end
      end)

    %Socket{channel_pid: pid, joins: %{@topic => %Join{topic: @topic, status: :joined}}}
  end

  test "a bare Slipstream push into a closing connection exits the caller" do
    socket = joined_socket(fn -> exit(:normal) end)

    assert {:normal, {GenServer, :call, _}} =
             catch_exit(Slipstream.push(socket, @topic, "trace", %{}))
  end

  test "push_event exits naming the call's exit reason, and logs the cause" do
    socket = joined_socket(fn -> exit(:normal) end)

    log =
      capture_log(fn ->
        assert catch_exit(Control.push_event(socket, @topic, "trace", %{})) ==
                 {:push_exited, :normal}
      end)

    assert log =~ "trace push failed (:normal); restarting the loopctl client"
  end

  @tag timeout: 15_000
  test "a push the connection never answers is a restart too, not a silent wait" do
    socket = joined_socket(fn -> Process.sleep(:infinity) end)

    capture_log(fn ->
      assert catch_exit(Control.push_event(socket, @topic, "stage", %{})) ==
               {:push_exited, :timeout}
    end)
  end

  test "the exit keeps the connection's own reason, detail included" do
    socket = joined_socket(fn -> exit({:shutdown, :disconnected}) end)

    capture_log(fn ->
      assert catch_exit(Control.push_event(socket, @topic, "trace", %{})) ==
               {:push_exited, {:shutdown, :disconnected}}
    end)
  end

  test "a joined socket whose connection already died restarts too" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    socket = %Socket{channel_pid: dead, joins: %{@topic => %Join{topic: @topic, status: :joined}}}

    capture_log(fn ->
      assert catch_exit(Control.push_event(socket, @topic, "status", %{})) ==
               {:push_exited, :not_connected}
    end)
  end

  # Started by the supervisor in the test below: reports itself, then pushes when told to.
  def start_pusher(test, socket_fun) do
    pid =
      spawn_link(fn ->
        send(test, {:pusher_started, self()})

        receive do
          :push -> Control.push_event(socket_fun.(), @topic, "trace", %{})
        end
      end)

    {:ok, pid}
  end

  test "under Control's own restart policy, a push exit is restarted, not stopped for good" do
    %{restart: restart} = Control.child_spec([])
    socket_fun = fn -> joined_socket(fn -> exit(:normal) end) end

    child = %{
      id: :pusher,
      start: {__MODULE__, :start_pusher, [self(), socket_fun]},
      restart: restart
    }

    capture_log(fn ->
      start_supervised!(%{
        id: :pusher_sup,
        start: {Supervisor, :start_link, [[child], [strategy: :one_for_one]]}
      })

      assert_receive {:pusher_started, first}
      send(first, :push)
      assert_receive {:pusher_started, second}, 2_000
      assert second != first
    end)
  end

  test "a push while not joined is still Slipstream's own error" do
    assert Control.push_event(%Socket{joins: %{}}, @topic, "stage", %{}) ==
             {:error, :not_joined}
  end

  # The wiring: a push site that calls Slipstream directly crashes without naming the cause.
  test "every push in Control goes through push_event" do
    source = File.read!("lib/loopctl_runner/control.ex")
    direct = Regex.scan(~r/(?<![_\w])push\(socket,/, source)
    assert length(direct) == 1, "only push_event itself may call Slipstream.push directly"
    # status, stage, dispatch_reply and trace, at least.
    assert length(Regex.scan(~r/push_event\(socket,/, source)) >= 4
  end
end
