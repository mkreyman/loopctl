defmodule Loopctl.Net.DnsResolver.Behaviour do
  @moduledoc """
  Behaviour for resolving a hostname to its IP addresses.

  Extracted so the SSRF egress guard (`Loopctl.Net.UrlGuard`) can be tested
  deterministically without real network DNS. Production resolves via
  `:inet.getaddrs/2`; tests swap in a Mox mock via config-based DI.
  """

  @doc """
  Resolves `host` to a non-empty list of A (IPv4) and AAAA (IPv6) addresses.

  Returns `{:ok, [ip_address]}` on success or `{:error, reason}` when the host
  does not resolve.
  """
  @callback resolve(host :: String.t()) ::
              {:ok, [:inet.ip_address()]} | {:error, term()}
end
