defmodule Loopctl.Test.EchoHostPlug do
  @moduledoc """
  Test-only Plug that echoes the `Host` request header it observed back in the
  response body. Used by the real Req/Finch round-trip test that verifies IP
  pinning sends the original hostname (not the pinned IP literal) as `Host`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    host =
      case get_req_header(conn, "host") do
        [value | _] -> value
        [] -> ""
      end

    send_resp(conn, 200, host)
  end
end
