defmodule LoopctlWeb.EndpointHttp2Test do
  @moduledoc """
  The bandit advisory CVE-2026-105659 is ignored in mix.exs ONLY because the endpoint serves
  no HTTP/2: `config/runtime.exs` sets `http_2_options: [enabled: false]`. This starts Bandit
  with the endpoint's own `http` options and speaks to it, so it fails if that option goes
  or stops meaning what the ignore entry says it means.
  """

  use ExUnit.Case, async: true

  defmodule Ok do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  setup do
    http = Application.fetch_env!(:loopctl, LoopctlWeb.Endpoint)[:http]

    server =
      start_supervised!(
        {Bandit,
         http
         |> Keyword.drop([:port, :ip])
         |> Keyword.merge(plug: Ok, port: 0, ip: :loopback, startup_log: false)}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    %{http: http, socket: socket}
  end

  test "the endpoint config switches HTTP/2 off", %{http: http} do
    assert get_in(http, [:http_2_options, :enabled]) == false
  end

  test "a connection opening with the HTTP/2 preface is closed unserved", %{socket: socket} do
    :ok = :gen_tcp.send(socket, @preface)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  test "HTTP/1.1 is still served", %{socket: socket} do
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")

    assert {:ok, "HTTP/1.1 200 OK" <> _} = :gen_tcp.recv(socket, 0, 1_000)
  end
end
