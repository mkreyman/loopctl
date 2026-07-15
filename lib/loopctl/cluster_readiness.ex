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
  (`warn_if_expected_peers_missing/0`, called from `Loopctl.Application`)
  `Logger.warning`s on exactly the two un-clustered classifications `readiness/0`
  reports and stays silent (INFO) otherwise: `:expected_peers_missing` (clustering
  configured — `DNS_CLUSTER_QUERY` set — AND expected — `EXPECTED_APP_NODES > 1` —
  yet peers missing) and `:clustering_expected_dns_unconfigured` (`EXPECTED_APP_NODES`
  raised above the single-node default of 2 but `DNS_CLUSTER_QUERY` forgotten). The
  standard `DNS_CLUSTER_QUERY`-unset single-node prod deploy (default
  `EXPECTED_APP_NODES` 2, no peers → `:single_node`) does NOT cry wolf. It is a WARN +
  runbook, not a crash. A single node must always boot. It does NOT set
  `DNS_CLUSTER_QUERY` and does NOT scale (both infra, out of scope).

  ## No sensitive data

  Everything this module exposes publicly is a BOUNDED, non-sensitive summary — a
  peer COUNT and a fixed-set `status` atom. It NEVER emits node NAMES or the query
  string, so it is safe to surface on the unauthenticated observability surface
  (the `loopctl.cluster.peers.count` Prometheus gauge on the internal metrics port,
  fed by `Loopctl.Telemetry.ScaleMetrics.poll_cluster_readiness/0`).

  ## Status classification

    * `:single_node` — `EXPECTED_APP_NODES <= 1`, OR `DNS_CLUSTER_QUERY` unset with an
      expected count at/below the single-node default (2): clustering is not
      required/enabled and the default count is indistinguishable from "never intended
      to cluster", so an empty `Node.list/0` is expected and correct — NOT an error.
    * `:clustered` — clustering configured, `EXPECTED_APP_NODES > 1`, and at least
      the expected number of peers (`peers >= expected_nodes - 1`) are connected.
    * `:expected_peers_missing` — clustering configured and `EXPECTED_APP_NODES > 1`
      but fewer peers than expected are connected (e.g. running un-clustered after a
      count bump). This is the state the boot WARN and the runbook gate exist to
      surface BEFORE it becomes a silent split-brain.
    * `:clustering_expected_dns_unconfigured` — `EXPECTED_APP_NODES` explicitly raised
      ABOVE the single-node default (`> 2`) yet `DNS_CLUSTER_QUERY` is UNSET. An
      operator bumped the node count but forgot to wire clustering, so the node runs
      un-clustered and — unlike `:expected_peers_missing` — peers can NEVER connect
      until DNS is set (it will not self-clear). Distinct from `:single_node` so the
      "silently un-clustered after a machine-count bump" case is not swallowed. The
      one detectable slice of the forgot-DNS class: at the DEFAULT count (2) it is
      indistinguishable from a normal single-node deploy and stays `:single_node`.
  """

  require Logger

  alias Loopctl.DbCapacity

  # The single-node baseline == `Loopctl.DbCapacity.expected_app_nodes/0`'s default
  # when `EXPECTED_APP_NODES` is unset (2). An expected count AT OR BELOW this with
  # `DNS_CLUSTER_QUERY` unset is indistinguishable from the standard single-node prod
  # deploy, so it classifies `:single_node` (no cry-wolf). Only a count strictly ABOVE
  # it proves an operator deliberately raised the node count — the DNS-forgotten case
  # this signal must surface. Kept in lockstep with the DbCapacity default by test.
  @single_node_baseline 2

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
                | :clustering_expected_dns_unconfigured
      }

  Resolves the live inputs (`expected_app_nodes/0`, `Node.list/0`, the DNS-query
  config) and delegates to the pure `readiness/3`.
  """
  @spec readiness() :: %{
          dns_cluster_query_configured: boolean(),
          peers: non_neg_integer(),
          expected_nodes: pos_integer(),
          status:
            :single_node
            | :clustered
            | :expected_peers_missing
            | :clustering_expected_dns_unconfigured
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
          status:
            :single_node
            | :clustered
            | :expected_peers_missing
            | :clustering_expected_dns_unconfigured
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

  # <= 1 expected node => single-node / not required (clustering never applies).
  defp clustering_status(expected_nodes, _peer_count, _dns?) when expected_nodes <= 1,
    do: :single_node

  # Clustering NOT configured (DNS_CLUSTER_QUERY unset). Two sub-cases, split on the
  # single-node baseline so the signal is actionable WITHOUT crying wolf:
  #
  #   * expected <= baseline (2, the DbCapacity default): INDISTINGUISHABLE from the
  #     standard single-node prod deploy (default `EXPECTED_APP_NODES` 2, DNS unset).
  #     Stay quiet as `:single_node` — a forgotten `DNS_CLUSTER_QUERY` at the default
  #     count cannot be told apart from "operator never intended to cluster", so
  #     warning here would fire on every normal boot (the cry-wolf we removed).
  #   * expected  > baseline: the operator EXPLICITLY raised `EXPECTED_APP_NODES` above
  #     the single-node default but left `DNS_CLUSTER_QUERY` unset — the exact
  #     "machine-count bump silently running un-clustered" failure this module exists
  #     to surface. This IS distinguishable, so it gets its own status
  #     (`:clustering_expected_dns_unconfigured`) and a boot WARN whose only guard is
  #     "set DNS_CLUSTER_QUERY first" (peers can never connect until it is set).
  defp clustering_status(expected_nodes, _peer_count, false) do
    if expected_nodes > @single_node_baseline,
      do: :clustering_expected_dns_unconfigured,
      else: :single_node
  end

  defp clustering_status(expected_nodes, peer_count, true) do
    if peer_count >= expected_nodes - 1, do: :clustered, else: :expected_peers_missing
  end

  @doc """
  Boot-time clustering-readiness WARN gate (AC-38.3.3). Called from
  `Loopctl.Application` after `Supervisor.start_link` (prod-guarded, mirroring
  `Loopctl.DbCapacity.warn_if_over_budget/0`): logs an actionable WARNING on exactly
  the two un-clustered classifications `readiness/0` reports — `:expected_peers_missing`
  (clustering configured, `EXPECTED_APP_NODES > 1`, peers short) and
  `:clustering_expected_dns_unconfigured` (`EXPECTED_APP_NODES` raised above the
  single-node default of 2 but `DNS_CLUSTER_QUERY` forgotten) — and an INFO otherwise.
  It NEVER raises and NEVER blocks boot — a single node always boots.

  Delegates to the DNS-aware `warn_if_expected_peers_missing/3` so the boot WARN and
  the readiness signal can never disagree about the same node (a `DNS_CLUSTER_QUERY`
  -unset single-node prod deploy at the DEFAULT count — `EXPECTED_APP_NODES` 2, no
  peers — is `:single_node`, so it does NOT warn; only a genuinely-configured-but-
  unclustered fleet, or a count explicitly bumped above the default with DNS
  forgotten, does).
  """
  @spec warn_if_expected_peers_missing() :: :ok
  def warn_if_expected_peers_missing do
    warn_if_expected_peers_missing(
      DbCapacity.expected_app_nodes(),
      peers(),
      dns_cluster_query_configured?()
    )
  end

  @doc """
  Pure, DNS-aware boot-WARN gate over injected inputs — the seam TC-38.3.3 drives
  directly with an expected-node count, a peer list, and whether `DNS_CLUSTER_QUERY`
  is configured, without mutating any env. Warns on the two un-clustered
  classifications — `:expected_peers_missing` (DNS configured + `EXPECTED_APP_NODES >
  1` + too few peers) and `:clustering_expected_dns_unconfigured` (`EXPECTED_APP_NODES`
  above the single-node default of 2 + DNS unset) — returns `:ok`, and never raises.
  Logs only bounded, non-sensitive values (counts) — never node names.

  ## Boot-time transient (why a lone WARN is not proof of a broken cluster)

  This is sampled ONCE, synchronously, at the end of `Application.start/2`.
  `DNSCluster` discovers and connects peers a few seconds LATER (its periodic DNS
  poll), so on a genuinely-healthy multi-node deploy `Node.list/0` can still be empty
  at this instant and this WARN can fire transiently during the startup window before
  peers connect. The reliable STEADY-STATE signal is the 10s-polled
  `loopctl.cluster.peers.count{status}` gauge (and `readiness/0`), NOT this
  point-in-time boot line — see the runbook. A persistent `:expected_peers_missing`
  on the gauge is the real alarm; a single boot WARN that clears is expected.
  """
  @spec warn_if_expected_peers_missing(pos_integer(), [node()], boolean()) :: :ok
  def warn_if_expected_peers_missing(expected_nodes, peers, dns_configured?)
      when is_integer(expected_nodes) and is_list(peers) and is_boolean(dns_configured?) do
    peer_count = length(peers)
    status = clustering_status(expected_nodes, peer_count, dns_configured?)

    case status do
      :expected_peers_missing ->
        Logger.warning(
          "Clustering readiness: EXPECTED_APP_NODES=#{expected_nodes} and DNS_CLUSTER_QUERY is " <>
            "configured but Node.list/0 shows #{peer_count} peer(s) — this node may be running " <>
            "UN-CLUSTERED (PubSub is node-local; the SthEnqueuer/rate-limiter cluster paths are " <>
            "inert). NOTE: peers connect a few seconds AFTER boot (async DNS poll), so a lone boot " <>
            "WARN that clears is the expected startup transient — trust the steady-state " <>
            "loopctl.cluster.peers.count{status} gauge, not this point-in-time line. If the gauge " <>
            "stays :expected_peers_missing, verify clustering is GREEN before raising machine count. " <>
            "See docs/user_stories/epic_38_scaling_readiness/README.md 'Runbook: verify clustering " <>
            "before scaling'. This is a WARN, not a crash — a single node always boots."
        )

      :clustering_expected_dns_unconfigured ->
        Logger.warning(
          "Clustering readiness: EXPECTED_APP_NODES=#{expected_nodes} (above the single-node " <>
            "default of #{@single_node_baseline}) but DNS_CLUSTER_QUERY is UNSET — BEAM clustering " <>
            "is NOT configured, so this node runs UN-CLUSTERED (PubSub is node-local; the " <>
            "SthEnqueuer/rate-limiter cluster paths are inert). An operator raised the node count " <>
            "without wiring clustering: unlike a missing-peers WARN, this will NOT self-clear — " <>
            "peers can never connect until DNS_CLUSTER_QUERY is set. GUARD: set the " <>
            "DNS_CLUSTER_QUERY Fly secret FIRST, then confirm the steady-state " <>
            "loopctl.cluster.peers.count{status=\"clustered\"} gauge before raising machine count. " <>
            "See docs/user_stories/epic_38_scaling_readiness/README.md 'Runbook: verify clustering " <>
            "before scaling'. This is a WARN, not a crash — a single node always boots."
        )

      _single_node_or_clustered ->
        Logger.info(
          "Clustering readiness OK (status=#{status}): expected_nodes=#{expected_nodes}, " <>
            "connected_peers=#{peer_count}, dns_configured=#{dns_configured?}"
        )
    end

    :ok
  rescue
    e -> Logger.warning("ClusterReadiness boot check skipped: #{Exception.message(e)}")
  end
end
