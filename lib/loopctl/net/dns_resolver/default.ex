defmodule Loopctl.Net.DnsResolver.Default do
  @moduledoc """
  Production DNS resolver backed by `:inet.getaddrs/3`.

  Resolves both A (IPv4) and AAAA (IPv6) records and returns the union, so the
  egress guard can reject a hostname that resolves to a private address over
  either address family.

  ## Bounded resolution (fail closed)

  Resolution runs under a bounded timeout — `:dns_resolve_timeout_ms` (default
  3000ms) — because `validate_egress`/`pin` run synchronously in the caller's
  process: web request processes (webhook changeset, ingestion enqueue, and the
  batch endpoint which validates items serially) and Oban jobs on shared
  concurrency-limited queues. An attacker-controlled nameserver that never
  answers would otherwise hang those slots for *all* tenants.

  Any resolution failure — NXDOMAIN, a socket error, OR a `:inet.getaddrs/3`
  timeout — collapses to `{:error, :unresolved}`, which the guard treats as a
  blocked host (fail closed). Both families must fail for the host to be
  considered unresolved.
  """

  @behaviour Loopctl.Net.DnsResolver.Behaviour

  @default_timeout_ms 3_000

  @impl true
  def resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)
    timeout = timeout_ms()

    addrs = lookup(charlist, :inet, timeout) ++ lookup(charlist, :inet6, timeout)

    case addrs do
      [] -> {:error, :unresolved}
      ips -> {:ok, ips}
    end
  end

  # Any getaddrs error (NXDOMAIN, socket error, or a runtime timeout the OTP
  # typespec omits) yields no addresses for that family — fail closed.
  defp lookup(charlist, family, timeout) do
    case :inet.getaddrs(charlist, family, timeout) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  end

  defp timeout_ms do
    Application.get_env(:loopctl, :dns_resolve_timeout_ms, @default_timeout_ms)
  end
end
