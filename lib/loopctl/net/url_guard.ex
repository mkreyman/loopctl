defmodule Loopctl.Net.UrlGuard do
  @moduledoc """
  Shared SSRF egress guard for every outbound HTTP request loopctl makes on
  behalf of a tenant (webhook delivery, knowledge content ingestion).

  A tenant supplies a URL; without a guard a tenant can point loopctl at
  internal infrastructure — the cloud metadata endpoint (`169.254.169.254`),
  Fly 6PN private networking (`fdaa::/16`), loopback, link-local, or any host
  that *resolves* to a private address — and read the response back out. This
  module closes that class of attack.

  Closes two private advisories:

    * ie-02 (GHSA-jh42-wf7g-f5rg) — webhook delivery: the old IPv4 string-prefix
      blocklist missed IPv6, decimal/hex/octal IPv4, `0.0.0.0`, and did no DNS
      resolution, and delivery followed redirects.
    * worker-01 (GHSA-j7m9-ffmr-pwhm) — content ingestion fetched a raw
      user-supplied URL with no validation.

  ## Defense layers

    1. **Scheme allowlist** — only `http`/`https` (override via `:schemes`).
    2. **Real DNS resolution (bounded)** — a bare host that is not already an IP
       literal is resolved (A *and* AAAA) via `Loopctl.Net.DnsResolver` under a
       bounded timeout (fail closed on timeout); a hostname that resolves to a
       private address is blocked. IP-literal forms (dotted v4, decimal/hex IPv4,
       and IPv6 literals) are parsed directly with `:inet.parse_address/1`.
    3. **Private-range blocklist for BOTH families** — v4: `0.0.0.0/8`,
       `10.0.0.0/8`, `100.64.0.0/10` (CGNAT), `127.0.0.0/8`, `169.254.0.0/16`
       (cloud metadata), `172.16.0.0/12`, `192.168.0.0/16`; v6: `::`, `::1`,
       `fe80::/10` (link-local), `fc00::/7` (ULA incl. Fly `fdaa::`), and every
       v4-in-v6 embedding that could smuggle a private v4 past the v6 rules —
       IPv4-mapped `::ffff:0:0/96`, IPv4-compatible `::/96`, NAT64
       `64:ff9b::/96` (RFC 6052), 6to4 `2002::/16` (RFC 3056), and Teredo
       `2001:0::/32` (RFC 4380). For every embedding the inner v4 is decoded and
       re-checked against the v4 rules. If a host resolves to *multiple*
       addresses and *any* one is blocked, the whole URL is rejected.

  ## Connecting safely — pin the validated IP

  Re-validating a hostname before a request is NOT sufficient on its own: an HTTP
  client re-resolves the hostname at connect time (a *separate* DNS lookup), so a
  TTL=0 attacker can answer the validation lookup with a public IP and the connect
  lookup with a private one (DNS rebinding / TOCTOU). To close that window,
  connection sites use `pin/1` + `pinned_request_opts/1`: the URL authority is
  rewritten to the *single* validated IP while the original hostname is preserved
  for the `Host` header, TLS SNI, and certificate verification (via Mint's
  `:hostname` connect option). The client therefore connects to exactly the IP the
  guard vetted — there is no second resolution to rebind.

  Callers MUST also disable redirect following (`redirect: false`) so a 302 hop
  can't re-enter an unvalidated URL.
  """

  import Bitwise

  @default_schemes ~w(http https)

  @type reason ::
          :invalid_url
          | :invalid_scheme
          | :missing_host
          | :dns_resolution_failed
          | :blocked_ip

  @typedoc """
  A validated URL together with the single IP it was pinned to and the original
  host to preserve for `Host`/SNI/cert verification.
  """
  @type pinned :: %{uri: URI.t(), host: String.t(), ip: :inet.ip_address()}

  @doc """
  Validates that `url` is safe to fetch from a server-side context.

  Returns `{:ok, %URI{}}` when the URL uses an allowed scheme and every address
  it resolves to is a public, routable address. Returns `{:error, reason}`
  otherwise, where `reason` is one of `t:reason/0`.

  Use this at submission/enqueue time (changeset, controller). At connection time
  prefer `pin/2` + `pinned_request_opts/1` to also close the DNS-rebinding window.

  ## Options

    * `:schemes` — list of allowed URI schemes (default `["http", "https"]`).
  """
  @spec validate_egress(String.t(), keyword()) :: {:ok, URI.t()} | {:error, reason()}
  def validate_egress(url, opts \\ []) do
    case pin(url, opts) do
      {:ok, %{uri: uri}} -> {:ok, uri}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Validates only the SHAPE of `url` — scheme allowlist and host presence —
  WITHOUT resolving DNS or applying the address denylist.

  Exposed for callers whose ADDRESS decision belongs to `Loopctl.Egress.Policy`
  rather than here (US-41.5): the webhook changeset validates shape at cast time,
  and the `Loopctl.Webhooks` context then makes the ONE policy call, which does
  the single DNS resolution and can see the OPERATOR deployment allowlist. Using
  `validate_egress/2` there instead would resolve the host TWICE for one write
  and re-decide the address with a copy of the rules that cannot see the
  allowlist. The scheme list still lives here, so there is no second policy.
  """
  @spec validate_shape(String.t(), keyword()) :: {:ok, URI.t()} | {:error, reason()}
  def validate_shape(url, opts \\ [])

  def validate_shape(url, opts) when is_binary(url) do
    schemes = Keyword.get(opts, :schemes, @default_schemes)
    uri = URI.parse(url)

    with :ok <- check_scheme(uri, schemes),
         {:ok, _host} <- host(uri) do
      {:ok, uri}
    end
  end

  def validate_shape(_url, _opts), do: {:error, :invalid_url}

  @doc """
  Validates `url` and returns the single IP to pin the connection to.

  Same checks as `validate_egress/2`, but on success returns
  `{:ok, %{uri: uri, host: host, ip: ip}}` where `ip` is the first (already
  vetted) resolved address. Feed the result to `pinned_request_opts/1` to build
  Req options that connect to that exact IP.
  """
  @spec pin(String.t(), keyword()) :: {:ok, pinned()} | {:error, reason()}
  def pin(url, opts \\ [])

  def pin(url, opts) when is_binary(url) do
    schemes = Keyword.get(opts, :schemes, @default_schemes)
    uri = URI.parse(url)

    with :ok <- check_scheme(uri, schemes),
         {:ok, host} <- host(uri),
         {:ok, ips} <- resolve(host),
         :ok <- check_ips(ips) do
      {:ok, %{uri: uri, host: strip_brackets(host), ip: hd(ips)}}
    end
  end

  def pin(_url, _opts), do: {:error, :invalid_url}

  @doc """
  Builds Req options that connect to the pinned IP while preserving the original
  host for the `Host` header, TLS SNI, and certificate verification.

  Returns `[url: connect_url, connect_options: [hostname: original_host],
  headers: [{"host", host_header} | extra_headers]]`, where `connect_url` has its
  authority rewritten to the validated IP literal (IPv6 bracketed).

  The `Host` header is set EXPLICITLY rather than relying on Mint's default: for
  an IPv6-pinned target, `Req.Finch.run/1` pre-injects `host` = the bracketed IPv6
  *literal* (because the rewritten URL host contains `:` and `:inet6` is unset),
  which would win over Mint's `put_new` Host and break vhost routing. Setting the
  header here makes Req's `put_new_header` a no-op. The value mirrors Mint's
  `default_host_header/1` (port suffix only when non-default for the scheme).

  Pass the caller's own headers as `extra_headers`; they are appended after the
  `Host` header. Merge the result with the caller's method/body/`redirect: false`.
  """
  @spec pinned_request_opts(pinned(), [{String.t(), String.t()}]) :: keyword()
  def pinned_request_opts(pinned, extra_headers \\ [])

  def pinned_request_opts(%{uri: uri, host: host, ip: ip}, extra_headers) do
    # Map-update (not %URI{uri | ...}) — `uri` arrives via a plain map pattern
    # so Elixir 1.19's stricter struct-update type check rejects the struct
    # form under --warnings-as-errors; the map update preserves the URI struct.
    connect_url =
      %{uri | host: ip_literal(ip), authority: nil}
      |> URI.to_string()

    host_header = {"host", host_header_value(host, uri.scheme, uri.port)}

    [
      url: connect_url,
      connect_options: [hostname: host],
      headers: [host_header | extra_headers]
    ]
  end

  # Mirrors Mint.HTTP1.default_host_header/1: host only when the port is the
  # scheme default, else "host:port". An IPv6-literal original host is bracketed.
  defp host_header_value(host, scheme, port) do
    bracketed = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host

    if URI.default_port(scheme) == port do
      bracketed
    else
      "#{bracketed}:#{port}"
    end
  end

  @doc """
  Resolves `host` (an IP literal or a hostname) to its address list WITHOUT
  applying the denylist.

  Exposed for `Loopctl.Egress.Policy` (US-41.4), which must be able to resolve a
  host the OPERATOR deployment allowlist deliberately carves out of the denylist
  (a loopback / private-range inference box). Pair it with `public_addresses?/1`
  for everything that is NOT allowlisted, so the denylist keeps living in exactly
  ONE module — there is no second, divergent URL policy (AC-41.4.9).
  """
  @spec resolve_host(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, reason()}
  def resolve_host(host) when is_binary(host), do: resolve(host)

  @doc """
  True when EVERY address in `ips` passes the private/loopback/CGNAT/link-local/
  ULA denylist (including every v4-in-v6 embedding). An empty list is never
  public — fail closed.
  """
  @spec public_addresses?([:inet.ip_address()]) :: boolean()
  def public_addresses?([]), do: false
  def public_addresses?(ips) when is_list(ips), do: check_ips(ips) == :ok

  # --- scheme / host ---

  defp check_scheme(%URI{scheme: scheme}, schemes) when is_binary(scheme) do
    if scheme in schemes, do: :ok, else: {:error, :invalid_scheme}
  end

  defp check_scheme(_uri, _schemes), do: {:error, :invalid_scheme}

  defp host(%URI{host: host}) when is_binary(host) and host != "" do
    {:ok, host}
  end

  defp host(_uri), do: {:error, :missing_host}

  # --- Resolution: IP literal first, else DNS ---

  defp resolve(host) do
    normalized = strip_brackets(host)

    case :inet.parse_address(String.to_charlist(normalized)) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        case dns_resolver().resolve(normalized) do
          {:ok, [_ | _] = ips} -> {:ok, ips}
          {:ok, []} -> {:error, :dns_resolution_failed}
          {:error, _} -> {:error, :dns_resolution_failed}
        end
    end
  end

  defp strip_brackets(host) do
    host
    |> String.replace_prefix("[", "")
    |> String.replace_suffix("]", "")
  end

  # `:inet.ntoa/1` yields the bare address; URI.to_string/1 re-brackets IPv6.
  defp ip_literal(ip), do: ip |> :inet.ntoa() |> List.to_string()

  # --- Blocklist ---

  # Any blocked address in the resolved set fails the whole URL.
  defp check_ips(ips) do
    if Enum.any?(ips, &blocked?/1), do: {:error, :blocked_ip}, else: :ok
  end

  # --- IPv4 ---
  defp blocked?({a, b, _c, _d}), do: blocked_ipv4?(a, b)

  # --- v4-in-v6 embeddings: decode the inner v4 and re-check the v4 rules ---

  # IPv4-mapped (::ffff:0:0/96)
  defp blocked?({0, 0, 0, 0, 0, 0xFFFF, g6, _g7}) do
    blocked_ipv4?(g6 >>> 8, g6 &&& 0xFF)
  end

  # IPv4-compatible (::0.0.0.0/96, incl. :: and ::1 → 0.0.0.1)
  defp blocked?({0, 0, 0, 0, 0, 0, g6, _g7}) do
    blocked_ipv4?(g6 >>> 8, g6 &&& 0xFF)
  end

  # NAT64 well-known prefix (64:ff9b::/96, RFC 6052)
  defp blocked?({0x0064, 0xFF9B, 0, 0, 0, 0, g6, _g7}) do
    blocked_ipv4?(g6 >>> 8, g6 &&& 0xFF)
  end

  # 6to4 (2002::/16, RFC 3056): inner v4 in groups 1..2
  defp blocked?({0x2002, w, _x, _, _, _, _, _}) do
    blocked_ipv4?(w >>> 8, w &&& 0xFF)
  end

  # Teredo (2001:0::/32, RFC 4380): client v4 is the low 32 bits XOR 0xFFFFFFFF
  defp blocked?({0x2001, 0, _, _, _, _, s6, s7}) do
    v4 = bnot(s6 <<< 16 ||| s7) &&& 0xFFFFFFFF
    blocked_ipv4?(v4 >>> 24, v4 >>> 16 &&& 0xFF)
  end

  # --- IPv6 ---
  # fe80::/10 link-local, fc00::/7 ULA (includes Fly fdaa::/16)
  defp blocked?({h0, _, _, _, _, _, _, _}) do
    (h0 &&& 0xFFC0) == 0xFE80 or (h0 &&& 0xFE00) == 0xFC00
  end

  defp blocked_ipv4?(0, _b), do: true
  defp blocked_ipv4?(10, _b), do: true
  defp blocked_ipv4?(127, _b), do: true
  defp blocked_ipv4?(169, 254), do: true
  defp blocked_ipv4?(192, 168), do: true
  defp blocked_ipv4?(172, b), do: b in 16..31
  defp blocked_ipv4?(100, b), do: b in 64..127
  defp blocked_ipv4?(_a, _b), do: false

  defp dns_resolver do
    Application.get_env(:loopctl, :dns_resolver, Loopctl.Net.DnsResolver.Default)
  end
end
