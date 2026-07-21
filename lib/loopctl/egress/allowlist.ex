defmodule Loopctl.Egress.Allowlist do
  @moduledoc """
  The OPERATOR-controlled deployment allowlist (US-41.4, AC-41.4.5 / AC-41.4.9).

  ## The trust root — read-only at EVERY role, including `:user`

  This is the ONLY thing that can carve specific hosts/CIDRs out of
  `Loopctl.Net.UrlGuard`'s loopback / private / CGNAT / link-local / Fly-6PN
  denylist. It is deployment-scoped configuration (`LOCAL_ENDPOINT_ALLOWLIST`),
  NOT tenant data: it lives outside RLS by design and there is deliberately NO
  API path that mutates it at any role. An agent must never be able to widen its
  own allowlist, and a `:user` key belongs to a tenant, not to the operator.

  Tenant-declared trusted endpoints (`Loopctl.Egress.TrustedEndpoint`) carve
  NOTHING out — they only change the locality VERDICT for hosts that already
  pass the denylist.

  ## Format

  A comma-separated list of entries, each either a bare host (`ollama.internal`,
  `127.0.0.1`) or a `host:port` (the port is ignored — locality is a HOST
  property) or an IPv4 CIDR (`10.1.0.0/16`):

      LOCAL_ENDPOINT_ALLOWLIST="127.0.0.1,localhost,ollama.internal,10.1.0.0/16"

  Configured as `config :loopctl, :local_endpoint_allowlist, [...]` (a list of
  strings) — see `config/runtime.exs`.

  ## Disclosure

  The allowlist CONTENTS are operator-plane infrastructure state (internal
  hostnames and CIDRs of the hosted deployment) and are precisely the target list
  an SSRF attacker wants. `Loopctl.Egress.posture/2` therefore returns only a
  BOOLEAN at role `:agent` (did the verdict come from the allowlist?) and the
  contents only at `:user` and above (AC-41.4.8).
  """

  @type entry :: {:host, String.t()} | {:cidr, :inet.ip4_address(), non_neg_integer()}

  @doc """
  The configured allowlist entries, parsed. Read-only: there is no writer.
  """
  @spec entries() :: [entry()]
  def entries, do: Enum.flat_map(raw_entries(), &parse/1)

  @doc "The raw configured strings — disclosed only at role `:user`+ (AC-41.4.8)."
  @spec raw_entries() :: [String.t()]
  def raw_entries do
    source().raw_entries()
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  # Config-based DI (never opts-based, never `Application.put_env` in a test).
  # Production reads deployment config; `config/test.exs` maps this to a
  # PROCESS-LOCAL source so an `async: true` test can exercise an operator
  # carve-out without mutating global state for its neighbours.
  defp source do
    Application.get_env(:loopctl, :local_allowlist_source, __MODULE__.Config)
  end

  @doc """
  True when `host` (a hostname or IP literal) matches an allowlist entry by name.

  Host-name matching is exact and case-insensitive.
  """
  @spec host_allowed?(String.t()) :: boolean()
  def host_allowed?(host) when is_binary(host) do
    normalized = String.downcase(host)
    Enum.any?(entries(), &match?({:host, ^normalized}, &1))
  end

  @doc """
  True when every address in `ips` falls inside an allowlisted CIDR (or the list
  is empty, which is never "allowed").

  ALL addresses must match: if a host resolves to one allowlisted address and one
  arbitrary private address, honouring it would let a split-horizon answer smuggle
  a non-allowlisted target past the carve-out.
  """
  @spec ips_allowed?([:inet.ip_address()]) :: boolean()
  def ips_allowed?([]), do: false

  def ips_allowed?(ips) when is_list(ips) do
    cidrs = for {:cidr, _, _} = c <- entries(), do: c
    hosts = for {:host, h} <- entries(), do: h

    Enum.all?(ips, fn ip ->
      literal = ip |> :inet.ntoa() |> List.to_string()
      literal in hosts or Enum.any?(cidrs, &in_cidr?(ip, &1))
    end)
  end

  defp in_cidr?({a, b, c, d}, {:cidr, {na, nb, nc, nd}, bits}) do
    mask = mask_for(bits)
    <<addr::32>> = <<a, b, c, d>>
    <<net::32>> = <<na, nb, nc, nd>>
    Bitwise.band(addr, mask) == Bitwise.band(net, mask)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp mask_for(bits) when bits in 0..32 do
    Bitwise.band(Bitwise.bsl(0xFFFFFFFF, 32 - bits), 0xFFFFFFFF)
  end

  defp parse(entry) do
    entry
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> do_parse()
  end

  defp do_parse(""), do: []

  defp do_parse(entry) do
    case String.split(entry, "/", parts: 2) do
      [addr, bits] -> parse_cidr(addr, bits)
      [host] -> [{:host, strip_port(host)}]
    end
  end

  defp parse_cidr(addr, bits) do
    with {bits_int, ""} <- Integer.parse(bits),
         true <- bits_int in 0..32,
         {:ok, {_, _, _, _} = ip} <- :inet.parse_address(String.to_charlist(addr)) do
      [{:cidr, ip, bits_int}]
    else
      _ -> []
    end
  end

  # `127.0.0.1:11434` — locality is a HOST property; drop the port. IPv6 literals
  # are bracketed, so only strip when there is exactly one colon.
  defp strip_port(host) do
    case String.split(host, ":") do
      [h, _port] -> h
      _ -> host |> String.trim_leading("[") |> String.trim_trailing("]")
    end
  end
end
