defmodule Loopctl.Net.DnsResolver.Default do
  @moduledoc """
  Production DNS resolver backed by `:inet.getaddrs/2`.

  Resolves both A (IPv4) and AAAA (IPv6) records and returns the union, so the
  egress guard can reject a hostname that resolves to a private address over
  either address family.
  """

  @behaviour Loopctl.Net.DnsResolver.Behaviour

  @impl true
  def resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    v4 = getaddrs(charlist, :inet)
    v6 = getaddrs(charlist, :inet6)

    case v4 ++ v6 do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  end
end
