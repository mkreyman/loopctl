defmodule LoopctlWeb.EndpointHttp2Test do
  @moduledoc """
  The bandit advisory CVE-2026-105659 is ignored in mix.exs ONLY because the endpoint serves
  no HTTP/2: `config/runtime.exs` sets `http_2_options: [enabled: false]`. This builds every
  listener the way the endpoint boots it (`Bandit.PhoenixAdapter.child_specs/2` over the
  endpoint's own config) and speaks to it, so it fails if that option goes, if a listener is
  added without it, or if it stops meaning what the ignore entry says it means.

  The prod block in runtime.exs re-sets `http:`, and that does not drop the option: `Config`
  deep-merges keyword lists, so its `ip:` joins the all-envs list rather than replacing it.
  """

  use LoopctlWeb.ConnCase, async: true

  defmodule Ok do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  # One deadline for every blocking :gen_tcp leg. endpoint_websocket_test.exs records why: a
  # 2s budget on this loopback round trip flaked the commit gate under load, and nothing here
  # is timing-dependent, so a short deadline is only exposure.
  @deadline 30_000
  @moduletag timeout: 4 * @deadline

  # The version the ignore entry in mix.exs was reasoned against.
  @acknowledged_bandit "1.12.5"

  defp listeners do
    config = [
      otp_app: :loopctl,
      http: LoopctlWeb.Endpoint.config(:http),
      https: LoopctlWeb.Endpoint.config(:https)
    ]

    for %{start: {Bandit, :start_link, [opts]}} = spec <-
          Bandit.PhoenixAdapter.child_specs(LoopctlWeb.Endpoint, config),
        do: {spec, opts}
  end

  # The listener the endpoint would boot, on an ephemeral loopback port and serving `Ok` in
  # place of the endpoint (whose requests would need the sandbox from Bandit's processes).
  defp connect({spec, opts}) do
    opts = Keyword.merge(opts, plug: Ok, port: 0, ip: :loopback, startup_log: false)
    server = start_supervised!(%{spec | start: {Bandit, :start_link, [opts]}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line], @deadline)

    socket
  end

  test "every listener the endpoint boots switches HTTP/2 off" do
    assert [_ | _] = listeners = listeners()

    for {_spec, opts} <- listeners do
      assert get_in(opts, [:http_2_options, :enabled]) == false,
             "#{opts[:scheme]} listener serves HTTP/2; CVE-2026-105659 is reachable"
    end
  end

  test "a connection opening with the HTTP/2 preface is closed unserved" do
    socket = listeners() |> hd() |> connect()
    :ok = :gen_tcp.send(socket, @preface)

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @deadline)
  end

  test "HTTP/1.1 is still served" do
    socket = listeners() |> hd() |> connect()
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")

    assert {:ok, "HTTP/1.1 200 OK\r\n"} = :gen_tcp.recv(socket, 0, @deadline)
  end

  test "bandit is still the version the ignored advisory was reasoned against" do
    assert to_string(Application.spec(:bandit, :vsn)) == @acknowledged_bandit,
           "bandit moved: recheck CVE-2026-105659 in mix.exs ignore_advisories " <>
             "(drop it if this version is patched), then update @acknowledged_bandit"
  end
end
