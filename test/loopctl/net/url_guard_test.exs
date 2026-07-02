defmodule Loopctl.Net.UrlGuardTest do
  @moduledoc """
  Unit tests for the shared SSRF egress guard.

  Closes ie-02 (GHSA-jh42-wf7g-f5rg) and worker-01 (GHSA-j7m9-ffmr-pwhm).

  IP-literal / numeric cases exercise the blocklist directly through
  `:inet.parse_address/1` and need no DNS. The DNS-rebinding cases inject the
  `Loopctl.MockDnsResolver` to prove a bare hostname is actually resolved and its
  resolved address is what gets checked.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Net.UrlGuard

  describe "validate_egress/2 blocks private / loopback / metadata IPv4 literals" do
    for {label, host} <- [
          {"cloud metadata", "169.254.169.254"},
          {"loopback", "127.0.0.1"},
          {"private 10/8", "10.0.0.5"},
          {"private 192.168/16", "192.168.1.1"},
          {"private 172.16/12", "172.16.0.1"},
          {"unspecified 0.0.0.0", "0.0.0.0"},
          {"CGNAT 100.64/10", "100.64.0.1"},
          {"decimal loopback", "2130706433"},
          {"hex loopback", "0x7f000001"}
        ] do
      test "blocks #{label} (#{host})" do
        assert {:error, :blocked_ip} =
                 UrlGuard.validate_egress("http://#{unquote(host)}/path")
      end
    end
  end

  describe "validate_egress/2 blocks private / loopback / metadata IPv6 literals" do
    for {label, host} <- [
          {"loopback ::1", "[::1]"},
          {"unspecified ::", "[::]"},
          {"Fly ULA fdaa::1", "[fdaa::1]"},
          {"link-local fe80::1", "[fe80::1]"},
          {"IPv4-mapped loopback", "[::ffff:127.0.0.1]"},
          {"IPv4-mapped metadata", "[::ffff:169.254.169.254]"},
          {"IPv4-compatible loopback", "[::127.0.0.1]"}
        ] do
      test "blocks #{label} (#{host})" do
        assert {:error, :blocked_ip} =
                 UrlGuard.validate_egress("https://#{unquote(host)}/path")
      end
    end
  end

  describe "validate_egress/2 with a public address" do
    test "allows a public IPv4 literal (no DNS)" do
      assert {:ok, %URI{host: "93.184.216.34"}} =
               UrlGuard.validate_egress("https://93.184.216.34/hooks")
    end

    test "allows a public IPv6 literal" do
      assert {:ok, %URI{}} = UrlGuard.validate_egress("https://[2606:2800:220:1::1]/x")
    end
  end

  describe "validate_egress/2 scheme allowlist" do
    test "rejects a non-http(s) scheme" do
      assert {:error, :invalid_scheme} =
               UrlGuard.validate_egress("ftp://93.184.216.34/x")
    end

    test "rejects file:// scheme" do
      assert {:error, :invalid_scheme} =
               UrlGuard.validate_egress("file:///etc/passwd")
    end

    test "honors a custom :schemes allowlist" do
      assert {:error, :invalid_scheme} =
               UrlGuard.validate_egress("http://93.184.216.34/x", schemes: ["https"])
    end

    test "rejects a URL with no host" do
      assert {:error, :missing_host} = UrlGuard.validate_egress("https:///path")
    end

    test "rejects a non-binary url" do
      assert {:error, :invalid_url} = UrlGuard.validate_egress(nil)
    end
  end

  describe "validate_egress/2 DNS resolution (rebinding defense)" do
    test "blocks a hostname that resolves to a private address" do
      expect(Loopctl.MockDnsResolver, :resolve, fn "rebind.example.com" ->
        {:ok, [{169, 254, 169, 254}]}
      end)

      assert {:error, :blocked_ip} =
               UrlGuard.validate_egress("https://rebind.example.com/steal")
    end

    test "blocks a hostname whose AAAA record is a private IPv6" do
      expect(Loopctl.MockDnsResolver, :resolve, fn "fly-internal.example.com" ->
        {:ok, [{0xFDAA, 0, 0, 0, 0, 0, 0, 1}]}
      end)

      assert {:error, :blocked_ip} =
               UrlGuard.validate_egress("https://fly-internal.example.com/x")
    end

    test "blocks when ANY of several resolved addresses is private" do
      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]}
      end)

      assert {:error, :blocked_ip} =
               UrlGuard.validate_egress("https://mixed.example.com/x")
    end

    test "allows a hostname that resolves only to public addresses" do
      expect(Loopctl.MockDnsResolver, :resolve, fn "good.example.com" ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      assert {:ok, %URI{host: "good.example.com"}} =
               UrlGuard.validate_egress("https://good.example.com/x")
    end

    test "rejects a hostname that does not resolve" do
      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:error, :nxdomain}
      end)

      assert {:error, :dns_resolution_failed} =
               UrlGuard.validate_egress("https://nope.example.com/x")
    end
  end
end
