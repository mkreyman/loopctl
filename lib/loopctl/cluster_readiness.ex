defmodule Loopctl.ClusterReadiness do
  @moduledoc """
  US-38.3 (AC-38.3.2/.3) — clustering-readiness verification signal + boot WARN gate.

  loopctl runs single-node today. Every horizontal-scaling capability in Epic 38 is
  code-only and env/flag-gated to that single-node behavior; this module adds the
  MISSING SIGNAL so a machine-count bump can't silently run un-clustered (node-local
  PubSub) with nobody noticing. It reports whether BEAM clustering is configured
  (`DNS_CLUSTER_QUERY`) and whether `Node.list/0` actually shows the expected peers
  (vs `EXPECTED_APP_NODES`, reused from `Loopctl.DbCapacity.expected_app_nodes/0` so
  the node count is parsed in exactly one place).

  ## What it is NOT

  It NEVER crashes and NEVER enforces. On a single node it reports `:single_node`
  ("clustering not required"), not an error. The boot check
  (`warn_if_expected_peers_missing/0`, called from `Loopctl.Application`) only
  `Logger.warning`s when you've told the app to expect peers (`EXPECTED_APP_NODES > 1`)
  but `Node.list/0` is empty — it is a WARN + runbook, not a crash. A single node
  must always boot. It does NOT set `DNS_CLUSTER_QUERY` and does NOT scale (both
  infra, out of scope).

  ## No sensitive data

  Everything this module exposes publicly is a BOUNDED, non-sensitive summary — a
  peer COUNT and a fixed-set `status` atom. It NEVER emits node NAMES or the query
  string, so it is safe to surface on the unauthenticated observability surface
  (the `loopctl.cluster.peers.count` Prometheus gauge on the internal metrics port,
  fed by `Loopctl.Telemetry.ScaleMetrics.poll_cluster_readiness/0`).

  ## Status classification

    * `:single_node` — `EXPECTED_APP_NODES <= 1` OR `DNS_CLUSTER_QUERY` unset:
      clustering is not required/enabled, so an empty `Node.list/0` is expected and
      correct — NOT an error.
    * `:clustered` — clustering configured, `EXPECTED_APP_NODES > 1`, and at least
      the expected number of peers (`peers >= expected_nodes - 1`) are connected.
    * `:expected_peers_missing` — clustering configured and `EXPECTED_APP_NODES > 1`
      but fewer peers than expected are connected (e.g. running un-clustered after a
      count bump). This is the state the boot WARN and the runbook gate exist to
      surface BEFORE it becomes a silent split-brain.
  """

  require Logger

  alias Loopctl.DbCapacity

  @doc """
  Whether BEAM clustering is configured via `DNS_CLUSTER_QUERY` (wired to
  `:dns_cluster_query` in `config/runtime.exs`; unset/empty → not configured →
  `DNSCluster` runs as `:ignore`). This story does NOT set the env.
  """
  @spec dns_cluster_query_configured?() :: boolean()
  def dns_cluster_query_configured? do
    case Application.get_env(:loopctl, :dns_cluster_query) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc """
  The currently-connected cluster peers (`Node.list/0`). Node names are used ONLY to
  derive a count in this module — they are never logged or exposed publicly.
  """
  @spec peers() :: [node()]
  def peers, do: Node.list()

  @doc """
  The clustering-readiness signal as a BOUNDED, non-sensitive map:

      %{
        dns_cluster_query_configured: boolean(),
        peers: non_neg_integer(),   # length(Node.list/0), never node names
        expected_nodes: pos_integer(),
        status: :single_node | :clustered | :expected_peers_missing
      }

  Resolves the live inputs (`expected_app_nodes/0`, `Node.list/0`, the DNS-query
  config) and delegates to the pure `readiness/3`.
  """
  @spec readiness() :: %{
          dns_cluster_query_configured: boolean(),
          peers: non_neg_integer(),
          expected_nodes: pos_integer(),
          status: :single_node | :clustered | :expected_peers_missing
        }
  def readiness do
    readiness(DbCapacity.expected_app_nodes(), peers(), dns_cluster_query_configured?())
  end

  @doc """
  Pure readiness classification from injected inputs — the seam tests drive directly
  (no env mutation, no real cluster) per the async-suite lesson: assert the outcome
  CLASS, not real timing/topology.
  """
  @spec readiness(pos_integer(), [node()], boolean()) :: %{
          dns_cluster_query_configured: boolean(),
          peers: non_neg_integer(),
          expected_nodes: pos_integer(),
          status: :single_node | :clustered | :expected_peers_missing
        }
  def readiness(expected_nodes, peers, dns_configured?)
      when is_integer(expected_nodes) and is_list(peers) and is_boolean(dns_configured?) do
    peer_count = length(peers)

    %{
      dns_cluster_query_configured: dns_configured?,
      peers: peer_count,
      expected_nodes: expected_nodes,
      status: clustering_status(expected_nodes, peer_count, dns_configured?)
    }
  end

  # <= 1 expected node OR clustering not configured => single-node / not required.
  defp clustering_status(expected_nodes, _peer_count, _dns?) when expected_nodes <= 1,
    do: :single_node

  defp clustering_status(_expected_nodes, _peer_count, false), do: :single_node

  defp clustering_status(expected_nodes, peer_count, true) do
    if peer_count >= expected_nodes - 1, do: :clustered, else: :expected_peers_missing
  end

  @doc """
  Boot-time clustering-readiness WARN gate (AC-38.3.3). Called from
  `Loopctl.Application` after `Supervisor.start_link` (prod-guarded, mirroring
  `Loopctl.DbCapacity.warn_if_over_budget/0`): logs an actionable WARNING when the
  app is told to expect peers (`EXPECTED_APP_NODES > 1`) but `Node.list/0` is empty
  (running un-clustered), and an INFO otherwise. It NEVER raises and NEVER blocks
  boot — a single node always boots.
  """
  @spec warn_if_expected_peers_missing() :: :ok
  def warn_if_expected_peers_missing do
    warn_if_expected_peers_missing(DbCapacity.expected_app_nodes(), peers())
  end

  @doc """
  Pure boot-WARN gate over injected inputs — the seam TC-38.3.3 drives directly with
  an expected-node count and a peer list, asserting a WARN is logged and `:ok` is
  returned (never a raise), without mutating `EXPECTED_APP_NODES`. Logs only bounded,
  non-sensitive values (counts) — never node names.
  """
  @spec warn_if_expected_peers_missing(pos_integer(), [node()]) :: :ok
  def warn_if_expected_peers_missing(expected_nodes, peers)
      when is_integer(expected_nodes) and is_list(peers) do
    peer_count = length(peers)

    if expected_nodes > 1 and peer_count == 0 do
      Logger.warning(
        "Clustering readiness: EXPECTED_APP_NODES=#{expected_nodes} but Node.list/0 is empty — " <>
          "this node is running UN-CLUSTERED (PubSub is node-local; the SthEnqueuer/rate-limiter " <>
          "cluster paths are inert). Verify clustering is GREEN before raising machine count. " <>
          "See docs/user_stories/epic_38_scaling_readiness/README.md 'Runbook: verify clustering " <>
          "before scaling'. This is a WARN, not a crash — a single node always boots."
      )
    else
      Logger.info(
        "Clustering readiness OK: expected_nodes=#{expected_nodes}, connected_peers=#{peer_count}"
      )
    end

    :ok
  rescue
    e -> Logger.warning("ClusterReadiness boot check skipped: #{Exception.message(e)}")
  end
end
