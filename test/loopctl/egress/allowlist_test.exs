defmodule Loopctl.Egress.AllowlistTest do
  @moduledoc """
  US-41.4 (AC-41.4.9) — the OPERATOR deployment allowlist parser.

  REGRESSION (review): `parse_cidr/2` accepted only IPv4 4-tuples with a 0..32
  prefix, so an IPv6 CIDR — including the Fly 6PN `fdaa::/16` range that both this
  module's and `TrustedEndpoint`'s moduledocs name as carve-outable ONLY through
  this list — was dropped with no error, no log and no boot-time validation.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Egress.Allowlist
  alias Loopctl.Test.AllowlistSource

  setup do
    on_exit(&AllowlistSource.clear/0)
    :ok
  end

  describe "CIDR parsing covers BOTH families" do
    test "an IPv4 CIDR matches inside its prefix and not outside" do
      AllowlistSource.put(["10.1.0.0/16"])

      assert Allowlist.ips_allowed?([{10, 1, 2, 3}])
      refute Allowlist.ips_allowed?([{10, 2, 2, 3}])
    end

    test "an IPv6 CIDR is parsed, not silently discarded" do
      AllowlistSource.put(["fdaa::/16"])

      assert [{:cidr, {0xFDAA, 0, 0, 0, 0, 0, 0, 0}, 16}] = Allowlist.entries()
      assert Allowlist.ips_allowed?([{0xFDAA, 0, 1, 0, 0, 0, 0, 5}])
      refute Allowlist.ips_allowed?([{0xFDAB, 0, 1, 0, 0, 0, 0, 5}])
    end

    test "families never cross: an IPv4 address is not inside an IPv6 prefix" do
      AllowlistSource.put(["fdaa::/16"])
      refute Allowlist.ips_allowed?([{10, 1, 2, 3}])
    end

    test "a dual-stack host is carve-out-able with one prefix per family" do
      AllowlistSource.put(["127.0.0.0/8", "::1/128"])

      # ALL addresses must match (a split-horizon answer must not smuggle a
      # non-allowlisted target past the carve-out), which is exactly why BOTH
      # families have to be expressible.
      assert Allowlist.ips_allowed?([{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}])
    end
  end

  describe "unparseable entries are surfaced, never silently dropped" do
    test "a bad prefix grants nothing AND is reported as a defect" do
      AllowlistSource.put(["10.1.0.0/99", "10.1.0.0/16"])

      refute Allowlist.ips_allowed?([{10, 1, 2, 3}, {192, 0, 2, 1}])
      assert Allowlist.ips_allowed?([{10, 1, 2, 3}])
      assert Allowlist.defects() == ["10.1.0.0/99"]
    end

    test "a well-formed list has no defects" do
      AllowlistSource.put(["127.0.0.1", "ollama.internal", "10.1.0.0/16", "fdaa::/16"])
      assert Allowlist.defects() == []
    end
  end

  describe "host matching" do
    test "is exact and case-insensitive, and ignores a port" do
      AllowlistSource.put(["Ollama.Internal:11434"])

      assert Allowlist.host_allowed?("ollama.internal")
      assert Allowlist.host_allowed?("OLLAMA.INTERNAL")
      refute Allowlist.host_allowed?("evil-ollama.internal")
    end
  end
end
