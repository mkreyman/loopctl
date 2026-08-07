defmodule Loopctl.Egress.Allowlist do
  @moduledoc """
  The OPERATOR-controlled deployment allowlist (US-41.4, AC-41.4.9).

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

  A comma-separated list of entries. Each entry is a bare host, a `host:port`, or
  a CIDR (IPv4 or IPv6), optionally qualified with the PURPOSES it grants:

      <host>[:<port>][@<purpose>[+<purpose>...]]
      <cidr>[@<purpose>[+<purpose>...]]

      LOCAL_ENDPOINT_ALLOWLIST="ollama.internal:11434,10.1.0.0/16,127.0.0.1:9000@webhook"

  Configured as `config :loopctl, :local_endpoint_allowlist, [...]` (a list of
  strings) — see `config/runtime.exs`.

  An entry that parses as NEITHER a host nor a CIDR — or that names a purpose
  this module does not know — is REJECTED LOUDLY (`Logger.warning`, and
  `defects/0` for the posture report) rather than silently discarded: a typo'd
  carve-out that fails open into "not allowlisted" is a fleet-wide outage nobody
  can see.

  IPv6 prefixes are first-class: the Fly 6PN range (`fdaa::/16`) is carve-outable
  ONLY through this list, so dropping v6 CIDRs would make the documented carve-out
  impossible.

  ### A carve-out grants the PURPOSE it names

  A carve-out is the operator saying "this private host is genuinely ours". WHAT
  loopctl may do with it is a separate question, and the answer differs sharply by
  purpose: `inference` reaches an endpoint the DEPLOYMENT resolves, while
  `webhook` and `ingest` reach a destination a TENANT writes. Granting all three
  from one unqualified entry means an Ollama carve-out also makes every host it
  covers a legal target for tenant-authored webhook POSTs and tenant-authored
  ingest fetches — reachability the operator never asked for. The same invariant
  is already enforced for tenant declarations
  (`Loopctl.Egress.declared_purposes/2`); this extends it to the operator plane so
  BOTH carve-out mechanisms are purpose-scoped.

  So an UNQUALIFIED entry grants `inference` ONLY — the purpose the allowlist
  exists for. `webhook` and `ingest` must be named:

      "ollama.internal:11434"                  # inference only
      "10.0.0.5@webhook"                       # webhook only
      "10.0.0.5:9000@inference+webhook"        # both, on port 9000 only

  `purposes/0` is the list of known purposes.

  ### A stated PORT binds; an omitted one does not

  `strip_port/1` used to DROP the port from a `host:port` entry, so
  `10.0.0.5:11434` granted `10.0.0.5` on every port — the operator's stated intent
  was discarded. A port written in an entry is now part of the carve-out: the
  entry matches that port and no other.

  An entry with NO port keeps matching any port. The alternative (default an
  unqualified entry to the scheme's default port) was considered and rejected: the
  documented, primary form of this list is a bare host for a service on a
  non-default port (`ollama.internal` for `:11434`), so that default would
  silently revoke every existing carve-out on upgrade — the exact
  believed-in-force-but-isn't failure `defects/0` exists to prevent. An operator
  who wants a port bound states it; the parser then honours the statement.

  CIDR entries carry no port syntax and are port-independent. There is no
  ambiguity to resolve there (nothing was ever written and dropped), and
  `fdaa::/16:8080` would be an unreadable grammar.

  ## Dual-stack hosts

  `ips_allowed?/1` requires EVERY resolved address to match (see its doc): a
  split-horizon answer must not smuggle a non-allowlisted target past the
  carve-out. A dual-stack host therefore needs BOTH families covered — by name
  (`host_allowed?/1` matches the name regardless of family) or by one CIDR per
  family. `allowed?/4` applies the same rule to the sub-list of entries that grant
  the requested purpose and port, so a purpose is never granted by an entry that
  covers only some of a host's addresses.

  ## Disclosure

  The allowlist CONTENTS are operator-plane infrastructure state (internal
  hostnames and CIDRs of the hosted deployment) and are precisely the target list
  an SSRF attacker wants. `Loopctl.Egress.posture/2` therefore returns only a
  BOOLEAN at role `:agent` (did the verdict come from the allowlist?) and the
  contents only at `:user` and above (AC-41.4.8).
  """

  require Logger

  @purposes [:inference, :webhook, :ingest]
  @default_purposes [:inference]

  @typedoc "A purpose a carve-out can grant. Mirrors `Loopctl.Egress.Policy.purpose/0`."
  @type purpose :: :inference | :webhook | :ingest

  @typedoc """
  A port constraint. `:any` when the entry stated no port; otherwise the exact
  port the entry stated.
  """
  @type port_constraint :: :any | 1..65_535

  @type entry ::
          {:host, String.t(), port_constraint(), [purpose()]}
          | {:cidr, :inet.ip_address(), non_neg_integer(), [purpose()]}

  @doc "The purposes a carve-out can grant."
  @spec purposes() :: [purpose()]
  def purposes, do: @purposes

  @doc """
  The configured allowlist entries, parsed. Read-only: there is no writer.
  """
  @spec entries() :: [entry()]
  def entries, do: Enum.flat_map(raw_entries(), &parse/1)

  @doc """
  The configured entries that could NOT be parsed as a host or a CIDR, or that
  named an unknown purpose.

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
  True when the carve-out covers `host`/`ips` FOR `purpose` on `port`.

  This is the question every locality decision asks; `host_allowed?/1` and
  `ips_allowed?/1` answer the weaker "is there any carve-out at all", which is
  what revalidation needs and what an admission decision must never use.

  `port` is `:any` when the caller genuinely has no port in hand (a host-granular
  report). It is NOT a wildcard: an entry that states a port does not match it,
  so an admission decision made without a concrete port fails closed rather than
  inheriting the widest grant.
  """
  @spec allowed?(String.t(), [:inet.ip_address()], purpose(), port_constraint()) :: boolean()
  def allowed?(host, ips, purpose, port) when is_binary(host) and is_list(ips) do
    granting = Enum.filter(entries(), &grants?(&1, purpose, port))

    host_matches?(granting, host) or ips_match?(granting, ips)
  end

  # An entry grants a request when it names the purpose AND its port constraint
  # admits the request's port. `:any` on the ENTRY side means "every port";
  # `:any` on the REQUEST side means "no port known", which only a portless entry
  # can satisfy.
  defp grants?(entry, purpose, port) do
    purpose in entry_purposes(entry) and port_admits?(entry_port(entry), port)
  end

  defp entry_purposes({:host, _host, _port, purposes}), do: purposes
  defp entry_purposes({:cidr, _ip, _bits, purposes}), do: purposes

  defp entry_port({:host, _host, port, _purposes}), do: port
  defp entry_port({:cidr, _ip, _bits, _purposes}), do: :any

  defp port_admits?(:any, _requested), do: true
  defp port_admits?(port, port), do: true
  defp port_admits?(_port, _requested), do: false

  @doc """
  True when `host` (a hostname or IP literal) matches an allowlist entry by name,
  for ANY purpose and port.

  Host-name matching is exact and case-insensitive. Use `allowed?/4` for an
  admission decision — this answers only "is this host carved out at all", which
  is what `Loopctl.Egress.Policy.reresolve/1` needs when it re-checks that a
  carve-out still exists.
  """
  @spec host_allowed?(String.t()) :: boolean()
  def host_allowed?(host) when is_binary(host), do: host_matches?(entries(), host)

  @doc """
  True when every address in `ips` falls inside an allowlisted CIDR (or the list
  is empty, which is never "allowed"), for ANY purpose and port.

  ALL addresses must match: if a host resolves to one allowlisted address and one
  arbitrary private address, honouring it would let a split-horizon answer smuggle
  a non-allowlisted target past the carve-out.
  """
  @spec ips_allowed?([:inet.ip_address()]) :: boolean()
  def ips_allowed?(ips) when is_list(ips), do: ips_match?(entries(), ips)

  defp host_matches?(entries, host) do
    normalized = String.downcase(host)
    Enum.any?(entries, &match?({:host, ^normalized, _port, _purposes}, &1))
  end

  defp ips_match?(_entries, []), do: false

  defp ips_match?(entries, ips) do
    cidrs = for {:cidr, _, _, _} = c <- entries, do: c
    hosts = for {:host, h, _port, _purposes} <- entries, do: h

    Enum.all?(ips, fn ip ->
      literal = ip |> :inet.ntoa() |> List.to_string()
      literal in hosts or Enum.any?(cidrs, &in_cidr?(ip, &1))
    end)
  end

  defp in_cidr?({_, _, _, _} = ip, {:cidr, {_, _, _, _} = net, bits, _purposes}) do
    prefix_match?(ipv4_int(ip), ipv4_int(net), bits, 32)
  end

  defp in_cidr?(
         {_, _, _, _, _, _, _, _} = ip,
         {:cidr, {_, _, _, _, _, _, _, _} = net, bits, _purposes}
       ) do
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
    case String.split(entry, "@", parts: 2) do
      [addr] -> parse_addr(entry, addr, @default_purposes)
      [addr, purposes] -> parse_qualified(entry, addr, purposes)
    end
  end

  defp parse_qualified(entry, addr, purposes) do
    case parse_purposes(purposes) do
      {:ok, parsed} -> parse_addr(entry, addr, parsed)
      :error -> reject(entry)
    end
  end

  # Purposes are `+`-separated, NOT comma-separated: the comma is the entry
  # separator of the env var itself, so `@inference,webhook` would arrive here as
  # two unrelated entries.
  defp parse_purposes(purposes) do
    parsed =
      purposes
      |> String.split("+")
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn p -> Enum.find(@purposes, &(to_string(&1) == p)) end)

    if parsed != [] and Enum.all?(parsed, &(&1 != nil)) do
      {:ok, Enum.uniq(parsed)}
    else
      :error
    end
  end

  defp parse_addr(entry, addr, purposes) do
    case String.split(addr, "/", parts: 2) do
      [net, bits] -> parse_cidr(entry, net, bits, purposes)
      [host] -> parse_host(entry, host, purposes)
    end
  end

  # BOTH families. An IPv6 prefix silently dropped here would make the Fly 6PN
  # (`fdaa::/16`) carve-out this module documents as its ONLY route impossible.
  defp parse_cidr(entry, addr, bits, purposes) do
    with {bits_int, ""} <- Integer.parse(bits),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
         true <- bits_int in 0..address_width(ip) do
      [{:cidr, ip, bits_int, purposes}]
    else
      _ -> reject(entry)
    end
  end

  defp address_width({_, _, _, _}), do: 32
  defp address_width({_, _, _, _, _, _, _, _}), do: 128

  # `127.0.0.1:11434` — the stated port is part of the carve-out (see the
  # moduledoc); an entry with no port matches any port. IPv6 literals are
  # bracketed, so only split when there is exactly one colon.
  defp parse_host(entry, host, purposes) do
    case String.split(host, ":") do
      [h, port] ->
        parse_host_port(entry, h, port, purposes)

      _ ->
        [{:host, host |> String.trim_leading("[") |> String.trim_trailing("]"), :any, purposes}]
    end
  end

  defp parse_host_port(entry, host, port, purposes) do
    case Integer.parse(port) do
      {port_int, ""} when port_int in 1..65_535 -> [{:host, host, port_int, purposes}]
      # A `host:` with a garbage port is a carve-out the operator believes is in
      # force on a specific port. Silently widening it to every port would be the
      # opposite of what they wrote, so it is a defect like any other.
      _ -> reject(entry)
    end
  end

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
          "#{inspect(entry)} — it grants NO carve-out. Expected host[:port][@purpose], " <>
          "or an IPv4/IPv6 CIDR[@purpose], where purpose is one of " <>
          "#{Enum.map_join(@purposes, "/", &to_string/1)} (`+`-separated for several)."
      )
    end

    []
  end
end
