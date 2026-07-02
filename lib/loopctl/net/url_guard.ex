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
    2. **Real DNS resolution** — a bare host that is not already an IP literal is
       resolved (A *and* AAAA) via `Loopctl.Net.DnsResolver`; a hostname that
       resolves to a private address is blocked. IP-literal forms (dotted v4,
       decimal/hex IPv4, and IPv6 literals) are parsed directly with
       `:inet.parse_address/1`.
    3. **Private-range blocklist for BOTH families** — v4: `0.0.0.0/8`,
       `10.0.0.0/8`, `100.64.0.0/10` (CGNAT), `127.0.0.0/8`, `169.254.0.0/16`
       (cloud metadata), `172.16.0.0/12`, `192.168.0.0/16`; v6: `::`, `::1`,
       `fe80::/10` (link-local), `fc00::/7` (ULA incl. Fly `fdaa::`), and
       IPv4-mapped `::ffff:0:0/96` (the embedded v4 is decoded and re-checked
       against the v4 rules). If a host resolves to *multiple* addresses and
       *any* one is blocked, the whole URL is rejected.

  Callers MUST re-validate on every request (DNS rebinding / TOCTOU), not only at
  submission time, and MUST disable redirect following (`redirect: false`) so a
  302 hop can't re-enter an unvalidated URL.
  """

  import Bitwise

  @default_schemes ~w(http https)

  @type reason ::
          :invalid_url
          | :invalid_scheme
          | :missing_host
          | :dns_resolution_failed
          | :blocked_ip

  @doc """
  Validates that `url` is safe to fetch from a server-side context.

  Returns `{:ok, %URI{}}` when the URL uses an allowed scheme and every address
  it resolves to is a public, routable address. Returns `{:error, reason}`
  otherwise, where `reason` is one of `t:reason/0`.

  ## Options

    * `:schemes` — list of allowed URI schemes (default `["http", "https"]`).
  """
  @spec validate_egress(String.t(), keyword()) :: {:ok, URI.t()} | {:error, reason()}
  def validate_egress(url, opts \\ [])

  def validate_egress(url, opts) when is_binary(url) do
    schemes = Keyword.get(opts, :schemes, @default_schemes)
    uri = URI.parse(url)

    with :ok <- check_scheme(uri, schemes),
         {:ok, host} <- host(uri),
         {:ok, ips} <- resolve(host),
         :ok <- check_ips(ips) do
      {:ok, uri}
    end
  end

  def validate_egress(_url, _opts), do: {:error, :invalid_url}

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

  # --- Blocklist ---

  # Any blocked address in the resolved set fails the whole URL.
  defp check_ips(ips) do
    if Enum.any?(ips, &blocked?/1), do: {:error, :blocked_ip}, else: :ok
  end

  # --- IPv4 ---
  defp blocked?({a, b, _c, _d}), do: blocked_ipv4?(a, b)

  # IPv4-mapped IPv6 (::ffff:0:0/96): decode the embedded v4's first two octets
  # (all blocked ranges are determined by them) and re-check against the v4 rules.
  defp blocked?({0, 0, 0, 0, 0, 0xFFFF, g6, _g7}) do
    blocked_ipv4?(g6 >>> 8, g6 &&& 0xFF)
  end

  # IPv4-compatible IPv6 (::0.0.0.0/96, incl. :: and ::1): decode the embedded v4
  # and re-check. Covers ::1 (→ 0.0.0.1, blocked by 0.0.0.0/8) and :: as well.
  defp blocked?({0, 0, 0, 0, 0, 0, g6, _g7}) do
    blocked_ipv4?(g6 >>> 8, g6 &&& 0xFF)
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
