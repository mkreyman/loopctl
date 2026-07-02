defmodule LoopctlWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` to the real client using `Loopctl.RemoteIp`, which
  resolves each forwarding header independently (immune to the `remote_ip`
  multi-header wire-order collapse that returns Fly's app IP).

  This REPLACES `plug RemoteIp` so every consumer of `conn.remote_ip` — the
  registration rate limiter, request logging, `SignupLive`, etc. — gets the
  correct client on Fly, from a single shared resolver.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Loopctl.RemoteIp.from(conn.req_headers) do
      nil -> conn
      addr -> %{conn | remote_ip: addr}
    end
  end
end
