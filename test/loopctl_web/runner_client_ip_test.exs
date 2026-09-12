defmodule LoopctlWeb.RunnerClientIpTest do
  @moduledoc """
  The runner socket is dispatched before the endpoint's plugs run, so its connect
  throttle must get the trusted client IP from `LoopctlWeb.RunnerClientIp`, which wraps
  the endpoint's `call/2`. These tests go through the real endpoint, so they fail if the
  wrap is not ahead of socket dispatch.
  """

  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.RunnerClientIp

  setup :verify_on_exit!

  defp capture_bucket do
    test_pid = self()

    Mox.expect(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window, _limit ->
      send(test_pid, {:bucket, bucket})
      {:allow, 1}
    end)
  end

  defp socket_request(conn, headers) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("x-loopctl-runner-token", "lc_not_a_runner")
    |> get("/runner/socket/websocket?vsn=2.0.0")
  end

  describe "through the endpoint" do
    test "the connect throttle is keyed on fly-client-ip, not on a spoofed header", %{conn: conn} do
      capture_bucket()

      conn =
        socket_request(conn, [
          {"fly-client-ip", "203.0.113.7"},
          {RunnerClientIp.header(), "9.9.9.9"}
        ])

      assert conn.status == 403
      assert_received {:bucket, "auth_ip:203.0.113.7"}
    end

    test "a spoofed header alone never reaches the throttle", %{conn: conn} do
      capture_bucket()

      conn = socket_request(conn, [{RunnerClientIp.header(), "9.9.9.9"}])

      assert conn.status == 403
      assert_received {:bucket, bucket}
      refute bucket == "auth_ip:9.9.9.9"
    end
  end

  describe "stamp/1" do
    test "replaces every inbound copy on a runner-socket path" do
      conn =
        Plug.Test.conn(:get, "/runner/socket/websocket")
        |> Map.update!(:req_headers, fn h ->
          [
            {"fly-client-ip", "203.0.113.7"},
            {"x-loopctl-client-ip", "1.1.1.1"},
            {"x-loopctl-client-ip", "2.2.2.2"} | h
          ]
        end)
        |> RunnerClientIp.stamp()

      assert Plug.Conn.get_req_header(conn, "x-loopctl-client-ip") == ["203.0.113.7"]
    end

    test "strips a spoofed copy and writes nothing when no client resolves" do
      conn =
        Plug.Test.conn(:get, "/runner/socket/websocket")
        |> Plug.Conn.put_req_header("x-loopctl-client-ip", "1.1.1.1")
        |> RunnerClientIp.stamp()

      assert Plug.Conn.get_req_header(conn, "x-loopctl-client-ip") == []
    end

    test "leaves every other path untouched" do
      conn =
        Plug.Test.conn(:get, "/api/v1/projects")
        |> Plug.Conn.put_req_header("fly-client-ip", "203.0.113.7")

      assert RunnerClientIp.stamp(conn) == conn
    end
  end
end
