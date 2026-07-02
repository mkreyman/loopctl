defmodule Loopctl.RemoteIpTest do
  use ExUnit.Case, async: true

  alias Loopctl.RemoteIp

  describe "from/1" do
    test "prefers fly-client-ip and ignores a forged x-forwarded-for" do
      headers = [
        {"x-forwarded-for", "9.9.9.9, 127.0.0.1"},
        {"fly-client-ip", "203.0.113.7"}
      ]

      assert RemoteIp.from(headers) == {203, 0, 113, 7}
    end

    test "is immune to Fly's app IP appended as the rightmost x-forwarded-for entry" do
      # The exact collapse a two-header RemoteIp config caused: a right-to-left
      # scan over the combined headers would return the app IP (66.241.125.10).
      # Resolving fly-client-ip independently returns the real client.
      headers = [
        {"fly-client-ip", "203.0.113.7"},
        {"x-forwarded-for", "203.0.113.7, 66.241.125.10"}
      ]

      assert RemoteIp.from(headers) == {203, 0, 113, 7}
    end

    test "falls back to x-forwarded-for off Fly (no fly-client-ip)" do
      assert RemoteIp.from([{"x-forwarded-for", "203.0.113.20"}]) == {203, 0, 113, 20}
    end

    test "returns nil when no forwarding headers are present" do
      assert RemoteIp.from([{"user-agent", "curl"}]) == nil
      assert RemoteIp.from([]) == nil
    end

    test "does not trust a forged x-forwarded-for from a non-proxy chain alone" do
      # A lone reserved suffix must not let the attacker pick the IP: with only
      # x-forwarded-for present RemoteIp returns the public client, but the
      # unspoofable fly-client-ip is what governs in production.
      assert RemoteIp.from([{"fly-client-ip", "invalid"}, {"x-forwarded-for", "9.9.9.9"}]) ==
               {9, 9, 9, 9}
    end
  end

  describe "string_from/1 and to_string_ip/1" do
    test "renders IPv4" do
      assert RemoteIp.string_from([{"fly-client-ip", "203.0.113.7"}]) == "203.0.113.7"
    end

    test "normalizes an IPv4-mapped IPv6 tuple to plain IPv4" do
      # ::ffff:203.0.113.7 — how Bandit surfaces IPv4 peers on a dual-stack bind.
      assert RemoteIp.to_string_ip({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}) == "203.0.113.7"
    end

    test "renders IPv6" do
      assert RemoteIp.to_string_ip({0x2606, 0x4700, 0, 0, 0, 0, 0, 1}) == "2606:4700::1"
    end

    test "returns nil for nil / non-address input" do
      assert RemoteIp.to_string_ip(nil) == nil
      assert RemoteIp.to_string_ip("nope") == nil
    end
  end
end
