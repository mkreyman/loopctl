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

  # v4-in-v6 transition embeddings that smuggle a private v4 (ie-02 follow-up).
  describe "validate_egress/2 blocks v4-in-v6 transition embeddings" do
    for {label, host} <- [
          # NAT64 well-known 64:ff9b::/96 (RFC 6052)
          {"NAT64 loopback", "[64:ff9b::7f00:1]"},
          {"NAT64 metadata", "[64:ff9b::a9fe:a9fe]"},
          {"NAT64 private-10", "[64:ff9b::a00:1]"},
          # 6to4 2002::/16 (RFC 3056)
          {"6to4 loopback", "[2002:7f00:1::]"},
          {"6to4 metadata", "[2002:a9fe:a9fe::]"},
          {"6to4 private-10", "[2002:a00:1::]"},
          # Teredo 2001:0::/32 (RFC 4380) — client v4 = low 32 bits XOR 0xFFFFFFFF
          {"Teredo loopback", "[2001:0:0:0:0:0:80ff:fffe]"},
          {"Teredo metadata", "[2001:0:0:0:0:0:5601:5601]"},
          {"Teredo private-10", "[2001:0:0:0:0:0:f5ff:fffe]"}
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

  # A hostile/unresponsive nameserver must not hang the caller — a bounded
  # resolve that times out fails CLOSED (blocked), never open (FIX B).
  describe "validate_egress/2 fails closed on DNS timeout" do
    test "a resolver timeout blocks the URL" do
      expect(Loopctl.MockDnsResolver, :resolve, fn _host ->
        {:error, :timeout}
      end)

      assert {:error, :dns_resolution_failed} =
               UrlGuard.validate_egress("https://slow.example.com/x")
    end
  end

  # pin/1 + pinned_request_opts/1 resolve ONCE and make the client connect to
  # that exact IP, so there is no second lookup to rebind (FIX C).
  describe "pin/2 and pinned_request_opts/1 (DNS-rebinding defense)" do
    test "pins the connection to the validated IP while preserving the host" do
      expect(Loopctl.MockDnsResolver, :resolve, fn "hooks.example.com" ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      assert {:ok, pinned} = UrlGuard.pin("https://hooks.example.com:8443/deliver?q=1")
      assert pinned.host == "hooks.example.com"
      assert pinned.ip == {93, 184, 216, 34}

      opts = UrlGuard.pinned_request_opts(pinned)
      # The connection target is the validated IP literal, NOT the hostname —
      # so the HTTP client cannot re-resolve and be rebound to a private IP.
      assert opts[:url] == "https://93.184.216.34:8443/deliver?q=1"
      # ...but the original host is preserved for Host header / TLS SNI / cert.
      assert opts[:connect_options] == [hostname: "hooks.example.com"]
      # Explicit Host header (non-default port → suffix) so Req's put_new_header
      # can't inject the IP literal.
      assert opts[:headers] == [{"host", "hooks.example.com:8443"}]
    end

    test "sets an explicit Host header with no suffix on the default port" do
      expect(Loopctl.MockDnsResolver, :resolve, fn "hooks.example.com" ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      assert {:ok, pinned} = UrlGuard.pin("https://hooks.example.com/deliver")
      opts = UrlGuard.pinned_request_opts(pinned)
      assert opts[:headers] == [{"host", "hooks.example.com"}]
    end

    test "IPv6-pinned target keeps the original hostname in the Host header (FIX 1)" do
      # Regression: a hostname resolving to an IPv6-only address must NOT send
      # `Host: [::1]`-style IP literals. Host header stays the hostname.
      expect(Loopctl.MockDnsResolver, :resolve, fn "v6only.example.com" ->
        {:ok, [{0x2606, 0x2800, 0x220, 1, 0, 0, 0, 1}]}
      end)

      assert {:ok, pinned} = UrlGuard.pin("https://v6only.example.com/deliver")
      opts = UrlGuard.pinned_request_opts(pinned)
      # Connect to the pinned v6 literal (bracketed in the URL)...
      assert opts[:url] == "https://[2606:2800:220:1::1]/deliver"
      # ...but Host header + SNI stay the hostname.
      assert opts[:connect_options] == [hostname: "v6only.example.com"]
      assert opts[:headers] == [{"host", "v6only.example.com"}]
    end

    test "appends caller headers after the Host header" do
      expect(Loopctl.MockDnsResolver, :resolve, fn _ -> {:ok, [{93, 184, 216, 34}]} end)

      assert {:ok, pinned} = UrlGuard.pin("https://hooks.example.com/x")
      opts = UrlGuard.pinned_request_opts(pinned, [{"x-sig", "abc"}])
      assert opts[:headers] == [{"host", "hooks.example.com"}, {"x-sig", "abc"}]
    end

    test "resolves the host exactly once (nothing left to rebind)" do
      # Mox verifies the arity-1 expectation was called exactly once on exit.
      expect(Loopctl.MockDnsResolver, :resolve, 1, fn _host ->
        {:ok, [{93, 184, 216, 34}]}
      end)

      assert {:ok, _pinned} = UrlGuard.pin("https://once.example.com/x")
    end

    test "pins a public IPv6 literal with brackets" do
      assert {:ok, pinned} = UrlGuard.pin("https://[2606:2800:220:1::1]/x")
      opts = UrlGuard.pinned_request_opts(pinned)
      assert opts[:url] == "https://[2606:2800:220:1::1]/x"
      assert opts[:connect_options] == [hostname: "2606:2800:220:1::1"]
      # An IPv6-literal original host is bracketed in the Host header too.
      assert opts[:headers] == [{"host", "[2606:2800:220:1::1]"}]
    end

    test "an IP-literal URL pins to itself" do
      assert {:ok, pinned} = UrlGuard.pin("https://93.184.216.34/hooks")
      opts = UrlGuard.pinned_request_opts(pinned)
      assert opts[:url] == "https://93.184.216.34/hooks"
      assert opts[:connect_options] == [hostname: "93.184.216.34"]
      assert opts[:headers] == [{"host", "93.184.216.34"}]
    end

    test "pin/1 rejects a blocked host (same checks as validate_egress)" do
      assert {:error, :blocked_ip} = UrlGuard.pin("http://169.254.169.254/latest")
    end
  end
end
