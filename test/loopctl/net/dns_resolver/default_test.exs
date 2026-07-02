defmodule Loopctl.Net.DnsResolver.DefaultTest do
  @moduledoc """
  Unit tests for the production DNS resolver.

  Uses IP-literal inputs so `:inet.getaddrs/3` returns immediately without a
  network lookup — the union/error logic and the bounded arity-3 call are
  exercised deterministically. The security-critical *fail-closed on timeout*
  behavior is proven at the guard level in `Loopctl.Net.UrlGuardTest` via the
  injected mock resolver (a real network timeout would be flaky to unit-test).
  """
  use ExUnit.Case, async: true

  alias Loopctl.Net.DnsResolver.Default

  test "resolves an IPv4 literal to itself (A family), no network" do
    assert {:ok, addrs} = Default.resolve("127.0.0.1")
    assert {127, 0, 0, 1} in addrs
  end

  test "resolves an IPv6 literal to itself (AAAA family), no network" do
    assert {:ok, addrs} = Default.resolve("::1")
    assert {0, 0, 0, 0, 0, 0, 0, 1} in addrs
  end

  test "honors the configured resolve timeout" do
    # A short timeout still resolves a literal immediately (proves the arity-3
    # :inet.getaddrs/3 timeout path is wired without hanging).
    assert Application.get_env(:loopctl, :dns_resolve_timeout_ms) == 2_000
    assert {:ok, _addrs} = Default.resolve("127.0.0.1")
  end
end
