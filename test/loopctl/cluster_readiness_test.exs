defmodule Loopctl.ClusterReadinessTest do
  @moduledoc """
  US-38.3 — clustering-readiness verification signal, boot WARN gate, and the
  DNSCluster supervision-tree wiring test.

  Covers TC-38.3.2 (readiness reports single-node / not-required, no sensitive
  data), TC-38.3.3 (EXPECTED_APP_NODES > 1 + empty Node.list → WARN, app still
  boots, never raises), and TC-38.3.4 (DNSCluster present in the supervision tree;
  unset `DNS_CLUSTER_QUERY` env resolves to `:ignore`).

  All classification/WARN cases are driven through the PURE `readiness/3` /
  `warn_if_expected_peers_missing/3` seams with injected inputs — no real cluster,
  no `EXPECTED_APP_NODES` env mutation — so the async suite asserts outcome CLASS,
  not real topology/timing (the async-suite flake lesson).
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Loopctl.ClusterReadiness

  describe "readiness/3 classification (AC-38.3.2)" do
    test "TC-38.3.2: <= 1 expected node is :single_node (clustering not required), never an error" do
      assert %{status: :single_node, expected_nodes: 1, peers: 0} =
               ClusterReadiness.readiness(1, [], false)

      # Even with a peer connected and DNS configured, a single expected node stays
      # :single_node — clustering is not required at count 1.
      assert %{status: :single_node} = ClusterReadiness.readiness(1, [:peer@host], true)
    end

    test "DNS unset at/below the single-node default (2) ⇒ :single_node (indistinguishable from a normal single-node deploy)" do
      # EXPECTED_APP_NODES unset defaults to 2 (DbCapacity). DNS unset at count 2 is
      # the standard single-node prod state — it must NOT be flagged, because a
      # forgotten DNS_CLUSTER_QUERY at the default count cannot be told apart from
      # "never intended to cluster".
      assert %{status: :single_node} = ClusterReadiness.readiness(2, [], false)
      assert %{status: :single_node} = ClusterReadiness.readiness(1, [], false)
    end

    test "MEDIUM FINDING: DNS unset with EXPECTED_APP_NODES raised ABOVE the default (>2) ⇒ :clustering_expected_dns_unconfigured (not silently :single_node)" do
      # The 'machine-count bump silently un-clustered' case the story exists to
      # surface: an operator explicitly raised the node count but left
      # DNS_CLUSTER_QUERY unset. This is distinguishable from the default single-node
      # deploy (count 2), so it gets its own status rather than being swallowed as
      # :single_node. Peer count is irrelevant — peers can never connect without DNS.
      assert %{status: :clustering_expected_dns_unconfigured} =
               ClusterReadiness.readiness(3, [], false)

      assert %{status: :clustering_expected_dns_unconfigured} =
               ClusterReadiness.readiness(5, [:a@h, :b@h], false)
    end

    test ":clustered when configured and the expected peers are connected" do
      # expected 2 nodes ⇒ need >= 1 peer.
      assert %{status: :clustered} = ClusterReadiness.readiness(2, [:peer@host], true)
      # expected 3 nodes ⇒ need >= 2 peers.
      assert %{status: :clustered} = ClusterReadiness.readiness(3, [:a@h, :b@h], true)
    end

    test ":expected_peers_missing when configured, > 1 expected, but too few peers" do
      assert %{status: :expected_peers_missing} = ClusterReadiness.readiness(2, [], true)
      assert %{status: :expected_peers_missing} = ClusterReadiness.readiness(3, [:a@h], true)
    end

    test "the signal is BOUNDED and carries NO sensitive data (no node names)" do
      readiness =
        ClusterReadiness.readiness(3, [:"secret-node@10.0.0.5", :"other@10.0.0.6"], true)

      # Exactly the four documented keys — nothing leaks a node name or a query string.
      assert readiness |> Map.keys() |> Enum.sort() ==
               [:dns_cluster_query_configured, :expected_nodes, :peers, :status]

      # `peers` is a COUNT (integer), never the node-name list.
      assert readiness.peers == 2
      assert is_integer(readiness.peers)

      assert readiness.status in [
               :single_node,
               :clustered,
               :expected_peers_missing,
               :clustering_expected_dns_unconfigured
             ]

      # No value in the map is (or contains) a node name atom/string.
      refute Enum.any?(Map.values(readiness), fn v ->
               is_atom(v) and String.contains?(to_string(v), "@")
             end)
    end
  end

  describe "readiness/0 on this (single) node (AC-38.3.2, TC-38.3.2)" do
    test "reports single-node / clustering-not-required, not an error" do
      readiness = ClusterReadiness.readiness()

      # The test node runs un-clustered with DNS_CLUSTER_QUERY unset, so this is the
      # 'clustering not required' state — never :expected_peers_missing (which would
      # be a false alarm on a single node) and never a raise.
      assert readiness.status == :single_node
      assert readiness.dns_cluster_query_configured == false
      assert is_integer(readiness.peers)
    end

    test "dns_cluster_query_configured?/0 is false when DNS_CLUSTER_QUERY is unset (test env)" do
      refute ClusterReadiness.dns_cluster_query_configured?()
    end

    test "the single-node baseline stays in lockstep with the DbCapacity default count" do
      # ClusterReadiness's :single_node vs :clustering_expected_dns_unconfigured split
      # hinges on the DbCapacity default node count (2). If that default ever changes,
      # this behavioral coupling catches it: at EXACTLY the default count with DNS
      # unset the signal must stay quiet (:single_node), and one above it must flag.
      default = Loopctl.DbCapacity.expected_app_nodes()

      assert %{status: :single_node} = ClusterReadiness.readiness(default, [], false)

      assert %{status: :clustering_expected_dns_unconfigured} =
               ClusterReadiness.readiness(default + 1, [], false)
    end
  end

  describe "warn_if_expected_peers_missing/3 boot gate (AC-38.3.3, TC-38.3.3)" do
    test "TC-38.3.3: DNS configured + EXPECTED_APP_NODES > 1 + empty Node.list WARNs and returns :ok (never raises)" do
      log =
        capture_log(fn ->
          assert :ok == ClusterReadiness.warn_if_expected_peers_missing(3, [], true)
        end)

      assert log =~ "Clustering readiness"
      assert log =~ "EXPECTED_APP_NODES=3"
      assert log =~ "UN-CLUSTERED"
      # It is documented as a WARN, not a crash.
      assert log =~ "WARN, not a crash"
      # The boot-time transient is self-described so operators don't chase a lone WARN.
      assert log =~ "gauge"
      # No node names are ever emitted (there are none here, but pin the contract).
      refute log =~ "@"
    end

    test "REGRESSION (medium finding): the standard single-node prod default does NOT warn" do
      # DNS_CLUSTER_QUERY unset (dns_configured? == false) with the DbCapacity default
      # EXPECTED_APP_NODES=2 and no peers is the EXACT current/correct prod state. It
      # must NOT fire the UN-CLUSTERED alarm — it is :single_node, matching readiness/0
      # (previously this path cried wolf on every normal single-node boot).
      log =
        capture_log(fn ->
          assert :ok == ClusterReadiness.warn_if_expected_peers_missing(2, [], false)
        end)

      refute log =~ "UN-CLUSTERED"
      refute log =~ "EXPECTED_APP_NODES"
    end

    test "MEDIUM FINDING: DNS unset + EXPECTED_APP_NODES raised above the default (>2) WARNs with a 'set DNS_CLUSTER_QUERY first' guard" do
      # The forgot-DNS-after-count-bump case must now produce a boot WARN (previously
      # it was swallowed as :single_node and emitted nothing). The message tells the
      # operator the specific guard and that it will NOT self-clear.
      log =
        capture_log(fn ->
          assert :ok == ClusterReadiness.warn_if_expected_peers_missing(3, [], false)
        end)

      assert log =~ "EXPECTED_APP_NODES=3"
      assert log =~ "UN-CLUSTERED"
      assert log =~ "DNS_CLUSTER_QUERY"
      # Distinct from the missing-peers WARN: this one cannot self-clear.
      assert log =~ "will NOT self-clear"
      assert log =~ "WARN, not a crash"
      refute log =~ "@"
    end

    test "the boot WARN mirrors readiness/3's un-clustered classifications exactly (DNS-gated)" do
      # For every (expected, peers, dns) triple the boot WARN fires IFF the readiness
      # classification is one of the two un-clustered states — :expected_peers_missing
      # or :clustering_expected_dns_unconfigured — so the two functions can never
      # disagree about the same node (the crux of the medium finding).
      warning_statuses = [:expected_peers_missing, :clustering_expected_dns_unconfigured]

      for {expected, peers, dns} <- [
            {1, [], false},
            {1, [], true},
            {2, [], false},
            {2, [], true},
            {2, [:peer@host], true},
            {3, [:a@h], true},
            {3, [:a@h, :b@h], true},
            {3, [], false},
            {5, [], false}
          ] do
        status = ClusterReadiness.readiness(expected, peers, dns).status

        log =
          capture_log(fn ->
            assert :ok == ClusterReadiness.warn_if_expected_peers_missing(expected, peers, dns)
          end)

        warned? = log =~ "UN-CLUSTERED"
        expected_warn? = status in warning_statuses

        assert warned? == expected_warn?,
               "expected warn?=#{expected_warn?} for " <>
                 "(#{expected}, #{inspect(peers)}, dns=#{dns}) [status=#{status}], got warn?=#{warned?}"
      end
    end

    test "a single expected node does NOT WARN and returns :ok" do
      # The OK case logs at INFO, which the suite's :warning primary level filters
      # out — so assert the behavioral contract instead: returns :ok and emits NO
      # un-clustered WARNING.
      log =
        capture_log(fn ->
          assert :ok == ClusterReadiness.warn_if_expected_peers_missing(1, [], true)
        end)

      refute log =~ "UN-CLUSTERED"
      refute log =~ "EXPECTED_APP_NODES"
    end

    test "expected > 1 WITH the peers connected does NOT WARN and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok == ClusterReadiness.warn_if_expected_peers_missing(2, [:peer@host], true)
        end)

      refute log =~ "UN-CLUSTERED"
      refute log =~ "EXPECTED_APP_NODES"
    end

    test "the app is booted and its top supervisor is alive (the WARN never blocks boot)" do
      # The boot-time call in Loopctl.Application is prod-guarded and rescue-wrapped;
      # this asserts the running app (which invoked the boot path) is healthy.
      assert is_pid(Process.whereis(Loopctl.Supervisor))
    end
  end

  describe "DNSCluster supervision-tree wiring (AC-38.3.4, TC-38.3.4)" do
    test "DNSCluster is a child of the app supervision tree" do
      children = Supervisor.which_children(Loopctl.Supervisor)

      # GOTCHA (documented in the story): with query :ignore, DNSCluster.start_link
      # returns :ignore and starts NO process — so its child pid is :undefined. Assert
      # on the CHILD SPEC presence (it IS wired into the tree), not on a running pid.
      dns_child = Enum.find(children, fn {id, _pid, _type, _mods} -> id == DNSCluster end)

      assert {DNSCluster, _pid, :worker, [DNSCluster]} = dns_child
    end

    test ":dns_cluster_query resolves from env — unset ⇒ :ignore" do
      # DNS_CLUSTER_QUERY is NOT set by this story; in the test env it is unset, so the
      # config resolves to nil and the child's query falls back to :ignore — exactly the
      # `{DNSCluster, query: Application.get_env(:loopctl, :dns_cluster_query) || :ignore}`
      # expression in Loopctl.Application.
      assert Application.get_env(:loopctl, :dns_cluster_query) == nil
      assert (Application.get_env(:loopctl, :dns_cluster_query) || :ignore) == :ignore
    end

    test "the dns_cluster dependency is available" do
      assert Code.ensure_loaded?(DNSCluster)
    end
  end
end
