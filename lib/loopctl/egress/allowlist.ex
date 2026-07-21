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
  property) or a CIDR, IPv4 OR IPv6 (`10.1.0.0/16`, `fdaa::/16`):

      LOCAL_ENDPOINT_ALLOWLIST="127.0.0.1,localhost,ollama.internal,10.1.0.0/16,fdaa::/16"

  Configured as `config :loopctl, :local_endpoint_allowlist, [...]` (a list of
  strings) — see `config/runtime.exs`.

  IPv6 prefixes are first-class: the Fly 6PN range (`fdaa::/16`) is carve-outable
  ONLY through this list, so dropping v6 CIDRs would make the documented carve-out
  impossible. An entry that parses as NEITHER a host nor a CIDR is REJECTED LOUDLY
  (`Logger.warning`, and `defects/0` for the posture report) rather than silently
  discarded — a typo'd carve-out that fails open into "not allowlisted" is a
  fleet-wide outage nobody can see.

  ## Dual-stack hosts

  `ips_allowed?/1` requires EVERY resolved address to match (see its doc): a
  split-horizon answer must not smuggle a non-allowlisted target past the
  carve-out. A dual-stack host therefore needs BOTH families covered — by name
  (`host_allowed?/1` matches the name regardless of family) or by one CIDR per
  family.

  ## Disclosure

  The allowlist CONTENTS are operator-plane infrastructure state (internal
  hostnames and CIDRs of the hosted deployment) and are precisely the target list
  an SSRF attacker wants. `Loopctl.Egress.posture/2` therefore returns only a
  BOOLEAN at role `:agent` (did the verdict come from the allowlist?) and the
  contents only at `:user` and above (AC-41.4.8).
  """

  require Logger

  @type entry :: {:host, String.t()} | {:cidr, :inet.ip_address(), non_neg_integer()}

  @doc """
  The configured allowlist entries, parsed. Read-only: there is no writer.
  """
  @spec entries() :: [entry()]
  def entries, do: Enum.flat_map(raw_entries(), &parse/1)

  @doc """
  The configured entries that could NOT be parsed as a host or a CIDR.

  An unparseable entry is a carve-out the operator BELIEVES is in force and that
  silently is not — surfaced here (and warned about when first parsed) instead of
  being dropped on the floor.
  """
  @spec defects() :: [String.t()]
  def defects do
    Enum.filter(raw_entries(), fn raw -> parse(raw) == [] and String.trim(raw) != "" end)
  end

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

  defp in_cidr?({_, _, _, _} = ip, {:cidr, {_, _, _, _} = net, bits}) do
    prefix_match?(ipv4_int(ip), ipv4_int(net), bits, 32)
  end

  defp in_cidr?({_, _, _, _, _, _, _, _} = ip, {:cidr, {_, _, _, _, _, _, _, _} = net, bits}) do
    prefix_match?(ipv6_int(ip), ipv6_int(net), bits, 128)
  end

  # Mixed families never match (an IPv4 address is not inside an IPv6 prefix).
  defp in_cidr?(_ip, _cidr), do: false

  defp prefix_match?(addr, net, bits, width) do
    mask = mask_for(bits, width)
    Bitwise.band(addr, mask) == Bitwise.band(net, mask)
  end

  defp ipv4_int({a, b, c, d}) do
    <<int::32>> = <<a, b, c, d>>
    int
  end

  defp ipv6_int({a, b, c, d, e, f, g, h}) do
    <<int::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    int
  end

  defp mask_for(bits, width) do
    full = Bitwise.bsl(1, width) - 1
    Bitwise.band(Bitwise.bsl(full, width - bits), full)
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
      [addr, bits] -> parse_cidr(entry, addr, bits)
      [host] -> [{:host, strip_port(host)}]
    end
  end

  # BOTH families. An IPv6 prefix silently dropped here would make the Fly 6PN
  # (`fdaa::/16`) carve-out this module documents as its ONLY route impossible.
  defp parse_cidr(entry, addr, bits) do
    with {bits_int, ""} <- Integer.parse(bits),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
         true <- bits_int in 0..address_width(ip) do
      [{:cidr, ip, bits_int}]
    else
      _ -> reject(entry)
    end
  end

  defp address_width({_, _, _, _}), do: 32
  defp address_width({_, _, _, _, _, _, _, _}), do: 128

  # NEVER silently. An unparseable entry is a carve-out the operator believes is
  # in force; failing open into "not allowlisted" without a word is how a
  # deployment-wide egress outage becomes undiagnosable.
  defp reject(entry) do
    # `entries/0` is consulted on every classification, so warn ONCE per distinct
    # bad entry rather than on every provider call.
    key = {__MODULE__, :rejected_entry, entry}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.warning(
        "Loopctl.Egress.Allowlist: ignoring unparseable LOCAL_ENDPOINT_ALLOWLIST entry " <>
          "#{inspect(entry)} — it grants NO carve-out. Expected a host, host:port, or an " <>
          "IPv4/IPv6 CIDR."
      )
    end

    []
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
