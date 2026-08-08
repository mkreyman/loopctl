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

      assert [{:cidr, {0xFDAA, 0, 0, 0, 0, 0, 0, 0}, 16, [:inference]}] = Allowlist.entries()
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
    test "is exact and case-insensitive" do
      AllowlistSource.put(["Ollama.Internal:11434"])

      assert Allowlist.host_allowed?("ollama.internal")
      assert Allowlist.host_allowed?("OLLAMA.INTERNAL")
      refute Allowlist.host_allowed?("evil-ollama.internal")
    end
  end

  # A carve-out states WHAT the deployment reaches this host FOR. Granting every
  # purpose from one entry would let an operator's model-endpoint carve-out double
  # as permission to POST tenant-authored webhook payloads (and to fetch
  # tenant-authored ingest URLs) anywhere it covers.
  describe "a carve-out grants only the purpose it names" do
    test "an unqualified entry grants inference and nothing else" do
      AllowlistSource.put(["ollama.internal"])

      assert Allowlist.allowed?("ollama.internal", [], :inference, :any)
      refute Allowlist.allowed?("ollama.internal", [], :webhook, :any)
      refute Allowlist.allowed?("ollama.internal", [], :ingest, :any)
    end

    test "a named purpose grants that purpose and REPLACES the default" do
      AllowlistSource.put(["10.0.0.5@webhook"])

      assert Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :webhook, :any)
      refute Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :inference, :any)
    end

    test "several purposes are `+`-separated (the comma is the entry separator)" do
      AllowlistSource.put(["10.0.0.5@inference+webhook"])

      assert Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :inference, :any)
      assert Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :webhook, :any)
      refute Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :ingest, :any)
    end

    test "a CIDR carve-out is purpose-scoped too" do
      AllowlistSource.put(["10.0.0.0/8"])

      assert Allowlist.allowed?("internal.example.com", [{10, 0, 0, 5}], :inference, :any)
      refute Allowlist.allowed?("internal.example.com", [{10, 0, 0, 5}], :ingest, :any)
    end

    test "an unknown purpose grants NOTHING and is reported as a defect" do
      AllowlistSource.put(["10.0.0.5@exfiltrate"])

      assert Allowlist.entries() == []
      assert Allowlist.defects() == ["10.0.0.5@exfiltrate"]
      refute Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :inference, :any)
    end

    test "the purpose filter applies the ALL-addresses rule to the granting subset" do
      # `.5` is covered for webhook, `.9` only for inference. A host resolving to
      # both is NOT webhook-allowlisted: honouring it would let the uncovered
      # address ride in on the covered one.
      AllowlistSource.put(["10.0.0.0/8", "10.0.0.5@webhook"])

      assert Allowlist.allowed?("dual.example.com", [{10, 0, 0, 5}], :webhook, :any)

      refute Allowlist.allowed?(
               "dual.example.com",
               [{10, 0, 0, 5}, {10, 0, 0, 9}],
               :webhook,
               :any
             )

      assert Allowlist.allowed?(
               "dual.example.com",
               [{10, 0, 0, 5}, {10, 0, 0, 9}],
               :inference,
               :any
             )
    end
  end

  # An operator who writes a port meant that port. Dropping it silently granted
  # every port on the host, which is strictly more than what was written.
  describe "a stated port binds the carve-out" do
    test "an entry with a port matches that port and no other" do
      AllowlistSource.put(["ollama.internal:11434"])

      assert Allowlist.allowed?("ollama.internal", [], :inference, 11_434)
      refute Allowlist.allowed?("ollama.internal", [], :inference, 8080)
      refute Allowlist.allowed?("ollama.internal", [], :inference, 80)
    end

    test "an entry with NO port still matches any port" do
      AllowlistSource.put(["ollama.internal"])

      assert Allowlist.allowed?("ollama.internal", [], :inference, 11_434)
      assert Allowlist.allowed?("ollama.internal", [], :inference, 80)
      assert Allowlist.allowed?("ollama.internal", [], :inference, :any)
    end

    # `:any` on the REQUEST side means "the caller has no port", not "every port".
    # A port-bound entry must not answer a question that never named its port.
    test "a port-bound entry does not answer a portless question" do
      AllowlistSource.put(["ollama.internal:11434"])

      refute Allowlist.allowed?("ollama.internal", [], :inference, :any)
    end

    test "port and purpose compose" do
      AllowlistSource.put(["10.0.0.5:9000@webhook"])

      assert Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :webhook, 9000)
      refute Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :webhook, 9001)
      refute Allowlist.allowed?("10.0.0.5", [{10, 0, 0, 5}], :inference, 9000)
    end

    test "a garbage port is a defect, never a silent widening to every port" do
      AllowlistSource.put(["ollama.internal:not-a-port"])

      assert Allowlist.defects() == ["ollama.internal:not-a-port"]
      refute Allowlist.allowed?("ollama.internal", [], :inference, 11_434)
      refute Allowlist.allowed?("ollama.internal", [], :inference, :any)
    end

    test "an IPv6 literal host is not mistaken for a host:port" do
      AllowlistSource.put(["[fdaa::1]"])

      assert Allowlist.host_allowed?("fdaa::1")
      assert Allowlist.allowed?("fdaa::1", [], :inference, 8080)
    end

    # REGRESSION (review): the colon-count heuristic read `[fdaa::1]:8080` as a
    # PORTLESS host literally named `fdaa::1]:8080`. It matched nothing and, since
    # the entry "parsed", was invisible to `defects/0` too — a carve-out the
    # operator believes is in force and silently is not, on the one address family
    # (Fly 6PN) this list is the only route for.
    test "a BRACKETED IPv6 literal with a port binds that port" do
      AllowlistSource.put(["[fdaa::1]:8080@webhook", "fdaa::2"])

      assert Allowlist.defects() == []
      assert Allowlist.allowed?("fdaa::1", [], :webhook, 8080)
      refute Allowlist.allowed?("fdaa::1", [], :webhook, 8081)
      # The unbracketed form is still a legal portless entry.
      assert Allowlist.ips_allowed?([{0xFDAA, 0, 0, 0, 0, 0, 0, 2}])
    end

    test "any other multi-colon entry is a defect, never an unmatchable host" do
      AllowlistSource.put(["10.0.0.5:11434:", "[fdaa::1]:8080:x"])

      assert Allowlist.defects() == ["10.0.0.5:11434:", "[fdaa::1]:8080:x"]
      assert Allowlist.entries() == []
    end

    # REGRESSION (review): `parse_purposes/1` trimmed each purpose but the address
    # half was never trimmed, so a space before the `@` left a host named
    # `"ollama.internal "` that matched nothing and was not a defect either.
    test "whitespace before the @ qualifier does not kill the carve-out" do
      AllowlistSource.put(["ollama.internal @inference+webhook"])

      assert Allowlist.defects() == []
      assert Allowlist.allowed?("ollama.internal", [], :webhook, 11_434)
    end
  end
end
