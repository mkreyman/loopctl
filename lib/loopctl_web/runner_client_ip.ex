defmodule LoopctlWeb.RunnerClientIp do
  @moduledoc """
  Hands the runner socket the TRUSTED client IP (issue #801).

  A Phoenix socket is dispatched by `plug :socket_dispatch`, which `use Phoenix.Endpoint`
  installs AHEAD of every plug the endpoint declares — so `LoopctlWeb.Plugs.ClientIp`
  has not run, and `connect_info` offers only `:x_headers` (headers starting `x-`) and
  the TCP peer. Neither is the client on Fly: `fly-client-ip` is not an `x-` header, the
  peer is the proxy, and the rightmost `x-forwarded-for` entry is Fly's own app IP
  (`Loopctl.RemoteIp`). Keying the connect throttle on any of those collapses every
  tenant's runners into one fail-closed bucket.

  So the endpoint wraps its own `call/2` (`__before_compile__/1`, registered after
  `use Phoenix.Endpoint`, so it runs before socket dispatch) and, for runner-socket paths
  only, replaces any client-supplied `#{"x-loopctl-client-ip"}` with the address
  `Loopctl.RemoteIp.from/1` resolves — `fly-client-ip` first. A client cannot set the
  header: every inbound copy is removed before the trusted one is written.
  """

  alias Plug.Conn

  @header "x-loopctl-client-ip"

  @doc "The header the trusted client IP is written to."
  @spec header() :: String.t()
  def header, do: @header

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts), do: super(LoopctlWeb.RunnerClientIp.stamp(conn), opts)
    end
  end

  @doc """
  Strips every inbound copy of the header and, on a runner-socket path, writes the
  resolved client IP. Other paths are returned untouched.
  """
  @spec stamp(Conn.t()) :: Conn.t()
  def stamp(%Conn{path_info: ["runner", "socket" | _]} = conn) do
    headers = Enum.reject(conn.req_headers, fn {name, _} -> name == @header end)

    case Loopctl.RemoteIp.string_from(headers) do
      nil -> %{conn | req_headers: headers}
      ip -> %{conn | req_headers: [{@header, ip} | headers]}
    end
  end

  def stamp(%Conn{} = conn), do: conn
end
