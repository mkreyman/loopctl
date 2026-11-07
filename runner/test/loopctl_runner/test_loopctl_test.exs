defmodule LoopctlRunner.TestLoopctlTest do
  @moduledoc """
  The shared stand-in endpoint does not let one test's connection answer into the next.

  Every Control test shares `TestLoopctl`'s endpoint, runner_id and scripted replies, and a server
  process reads `test_pid` when it HANDLES a frame. A frame a dying Control sent during teardown —
  ControlMergeTest's run ending `:shutdown` once its Task.Supervisor stopped, reported as
  `session_escalated` — was handled after the next test installed itself, and reached that test.
  `TestLoopctl.start/2` therefore waits for every earlier connection's server processes to exit
  before installing a test, and raises on one still open.
  """

  # The shared endpoint and its Agent are the subject.
  use ExUnit.Case, async: false

  alias LoopctlRunner.{Control, ControlConfig, TestLoopctl}

  import LoopctlRunner.TestSupport

  setup do
    {:ok, port} = TestLoopctl.start(self())
    root = tmp_dir!("test-loopctl")
    token_file = Path.join(root, "token")
    File.write!(token_file, TestLoopctl.get(:token) <> "\n")
    File.chmod!(token_file, 0o600)

    control = %ControlConfig{
      url: "ws://127.0.0.1:#{port}/runner/socket/websocket",
      runner_id: TestLoopctl.get(:runner_id),
      machine: "testbox",
      token_file: token_file,
      repos: ["mkreyman/fixture"],
      max_sessions: 1,
      status_interval_s: 30
    }

    {:ok, config: %{config!(root) | control: control}}
  end

  defp joined_control(ctx) do
    test = self()

    {:ok, pid} =
      GenServer.start(Control,
        config: ctx.config,
        on_fatal: &send(test, {:fatal, &1}),
        forge: fn _repo, _head, _base, _timeout -> {:ok, []} end
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok = wait_until(fn -> Control.info(pid).joined end, 5_000)
    pid
  end

  test "a test is installed only once every earlier connection's server processes have exited",
       ctx do
    pid = joined_control(ctx)
    serving = TestLoopctl.get(:server_pids)
    # The transport and the channel, at least.
    assert length(serving) >= 2
    assert Enum.all?(serving, &Process.alive?/1)

    GenServer.stop(pid)
    {:ok, _port} = TestLoopctl.start(self())

    refute Enum.any?(serving, &Process.alive?/1)
    assert TestLoopctl.get(:server_pids) == []
  end

  test "a connection still open is a leaked Control, and installing the next test raises", ctx do
    pid = joined_control(ctx)

    assert_raise RuntimeError, ~r/still open after 200ms: a Control was left running/, fn ->
      TestLoopctl.start(self(), quiesce_ms: 200)
    end

    GenServer.stop(pid)
    assert {:ok, _port} = TestLoopctl.start(self())
  end
end
