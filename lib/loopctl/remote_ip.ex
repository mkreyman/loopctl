defmodule Loopctl.RemoteIp do
  @moduledoc """
  Single source of truth for resolving the real client IP from request headers,
  robust against the `remote_ip` multi-header wire-order collapse.

  `RemoteIp.Headers.take/2` preserves WIRE ORDER and concatenates the IPs from
  ALL configured headers into one list, which `RemoteIp` then scans right-to-left.
  So a two-header config `["fly-client-ip", "x-forwarded-for"]` returns whatever
  IP is rightmost on the wire — which on Fly is the app-assigned IP that fly-proxy
  appends to `x-forwarded-for`, collapsing every visitor onto one IP.

  We avoid that by resolving each header INDEPENDENTLY with a singleton `:headers`
  list, preferring the unspoofable `fly-client-ip` (fly-proxy overwrites any
  client-supplied value) and falling back to `x-forwarded-for` (off-Fly / nginx).
  The configured `:proxies` (Fly's `fdaa::/16` 6PN by default) are honored so
  reserved/proxy hops are peeled.

  Used by BOTH `LoopctlWeb.Plugs.ClientIp` (which sets `conn.remote_ip` for the
  whole HTTP pipeline) and `LoopctlWeb.SignupLive.signup_session/1`, so every
  consumer resolves the client identically.
  """

  @fly_client_ip "fly-client-ip"
  @forwarded_for "x-forwarded-for"

  @doc """
  Resolves the client IP from a list of request headers, or `nil`.

  Prefers `fly-client-ip`, then `x-forwarded-for`. Each is resolved via a
  separate singleton-header `RemoteIp.from/2` call so the wire-order collapse
  cannot occur.
  """
  @spec from(Plug.Conn.headers()) :: :inet.ip_address() | nil
  def from(headers) when is_list(headers) do
    resolve_header(headers, @fly_client_ip) || resolve_header(headers, @forwarded_for)
  end

  def from(_), do: nil

  @doc "Like `from/1` but returns a normalized string (or `nil`)."
  @spec string_from(Plug.Conn.headers()) :: String.t() | nil
  def string_from(headers), do: headers |> from() |> to_string_ip()

  @doc """
  True when `addr` is within one of the configured `:proxies` CIDRs.

  Used so the raw TCP peer is never treated as a per-visitor identity when it is
  actually the proxy (keying on it would collapse every visitor onto one bucket).
  """
  @spec proxy?(:inet.ip_address() | term()) :: boolean()
  def proxy?(addr) when tuple_size(addr) in [4, 8] do
    encoded = RemoteIp.Block.encode(addr)
    Enum.any?(proxy_blocks(), &RemoteIp.Block.contains?(&1, encoded))
  end

  def proxy?(_), do: false

  @doc """
  Normalizes an `:inet.ip_address/0` tuple to a stable string.

  IPv4-mapped IPv6 (`::ffff:a.b.c.d`, i.e. `{0,0,0,0,0,0xffff,_,_}` — how Bandit
  surfaces IPv4 peers on a dual-stack `::` bind) is rendered as the plain IPv4
  form so buckets are stable regardless of the socket family.
  """
  @spec to_string_ip(:inet.ip_address() | nil | term()) :: String.t() | nil
  def to_string_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    <<a, b, c, d>> = <<ab::16, cd::16>>
    to_string_ip({a, b, c, d})
  end

  def to_string_ip(addr) when tuple_size(addr) in [4, 8], do: addr |> :inet.ntoa() |> to_string()
  def to_string_ip(_), do: nil

  defp resolve_header(headers, header_name) do
    RemoteIp.from(headers, Keyword.put(opts(), :headers, [header_name]))
  end

  defp proxy_blocks do
    opts() |> Keyword.get(:proxies, []) |> Enum.map(&RemoteIp.Block.parse!/1)
  end

  defp opts, do: Application.get_env(:loopctl, :remote_ip_opts, [])
end
