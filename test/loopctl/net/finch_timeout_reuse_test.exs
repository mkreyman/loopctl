defmodule Loopctl.Net.FinchTimeoutReuseTest do
  @moduledoc """
  PINS why mint stays below 1.11.0 (mix.exs, `hex: ignore_advisories`, PR #926).

  mint 1.11.0 stopped closing a connection on a receive timeout, and Finch 0.23.0 returns an
  open connection to its pool, so the NEXT request on it reads the late response of the one
  that timed out and crashes with a CaseClauseError. On mint 1.10.1 the timed-out connection
  is closed and the next request gets a fresh one. A pool of ONE forces the reuse.

  This fails on mint >= 1.11.0 until Finch closes the connection itself; when it passes on a
  newer mint, the pin and the mint advisory entries can go.
  """

  use ExUnit.Case, async: true

  defmodule SlowThenFast do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{request_path: "/slow"} = conn, _opts) do
      Process.sleep(400)
      Plug.Conn.send_resp(conn, 200, "late")
    end

    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "fast")
  end

  test "the request after a receive timeout gets its own answer, not a crash" do
    {:ok, server} =
      start_supervised({Bandit, plug: SlowThenFast, port: 0, ip: :loopback, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    finch = :"finch_timeout_reuse_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})

    base = "http://127.0.0.1:#{port}"

    assert {:error, _timeout} =
             Req.get("#{base}/slow", finch: finch, receive_timeout: 100, retry: false)

    Process.sleep(500)

    assert {:ok, %Req.Response{status: 200, body: "fast"}} =
             Req.get("#{base}/fast", finch: finch, retry: false)
  end
end
