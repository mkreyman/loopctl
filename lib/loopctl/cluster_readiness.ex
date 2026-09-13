defmodule Loopctl.ClusterReadiness do
  @moduledoc """
  US-38.3 (AC-38.3.2/.3) — clustering-readiness verification signal + boot WARN gate.

  Production runs two Fly machines clustered over the private network: `DNS_CLUSTER_QUERY`
  and `EXPECTED_APP_NODES` are set in `fly.toml` `[env]`, and `rel/env.sh.eex` names each
  node after its 6PN address with IPv6 distribution. This module is the SIGNAL that the
  machines actually found each other, so a fleet can't silently run un-clustered
  (node-local PubSub) with nobody noticing. It reports whether BEAM clustering is configured
  (`DNS_CLUSTER_QUERY`) and whether `Node.list/0` actually shows the expected peers
  (vs `EXPECTED_APP_NODES`, reused from `Loopctl.DbCapacity.expected_app_nodes/0` so
  the node count is parsed in exactly one place).

  ## What it is NOT

  ## A node name no peer can reach

  `DNS_CLUSTER_QUERY` alone does not cluster anything: DNSCluster connects to
  `<basename>@<address>`, so a node named on a loopback host (`loopctl@127.0.0.1`, the
  off-Fly default in `rel/env.sh.eex`) or not distributed at all can never be reached,
  and `:expected_peers_missing` would read as a slow start forever. The boot check says so
  separately (`warn_if_distribution_unroutable/2`), naming only the CLASS of the host,
  never the node name.

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
    * `:peers_may_be_suspended` — fewer peers than `EXPECTED_APP_NODES` expects, on a
      deployment that has declared its peers may be suspended (`CLUSTER_PEERS_MAY_SUSPEND=true`,
      set in `fly.toml` next to `auto_stop_machines`), AND every machine the clustering DNS
      query currently lists is connected. There `EXPECTED_APP_NODES` is the machine count
      that CAN run (the DB connection budget needs that), not the count that is running.
      The switch alone never decides it: the query is resolved the way DNSCluster resolves
      it (`unconnected_running_peers/3`), and if it lists a machine other than this one that is not
      connected — both machines running, clustering broken — the status is
      `:expected_peers_missing` with its WARN, switch or not. A lookup that fails is not
      evidence either, and alarms. A deployment that always runs every machine leaves the
      switch unset. `connected_peers/0` (`loopctl.cluster.peers.connected`) still says how
      many are connected.
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
  How many BEAM peers this node is connected to, with no judgement about how many there
  should be. The readiness `status` compares the count with `EXPECTED_APP_NODES`; this
  reading only reports it (the `loopctl.cluster.peers.connected` gauge), so a machine that
  is merely suspended never reads as an alarm here. Clustering verification asserts it is
  `1` on both machines while both run.
  """
  @spec connected_peers() :: non_neg_integer()
  def connected_peers, do: length(peers())

  @doc """
  The clustering-readiness signal as a BOUNDED, non-sensitive map:

      %{
        dns_cluster_query_configured: boolean(),
        peers: non_neg_integer(),   # length(Node.list/0), never node names
        expected_nodes: pos_integer(),
        status: :single_node | :clustered | :expected_peers_missing
                | :peers_may_be_suspended | :clustering_expected_dns_unconfigured
      }

  Resolves the live inputs (`expected_app_nodes/0`, `Node.list/0`, the DNS-query
  config, `peers_may_suspend?/0`, and — only when it can change the answer — the DNS
  evidence of `unconnected_running_peers/3`) and delegates to the pure `readiness/5`.

  The lookup is bounded (`Loopctl.ClusterReadiness.InetResolver`: A and AAAA, 500 ms each),
  because this runs in the 10 s telemetry poller alongside the Oban gauges and in the boot
  check, and a dead resolver must cost at most about a second there.
  """
  @spec readiness() :: %{
          dns_cluster_query_configured: boolean(),
          peers: non_neg_integer(),
          expected_nodes: pos_integer(),
          status:
            :single_node
            | :clustered
            | :expected_peers_missing
            | :peers_may_be_suspended
            | :clustering_expected_dns_unconfigured
        }
  def readiness do
    expected = DbCapacity.expected_app_nodes()
    peers = peers()
    dns? = dns_cluster_query_configured?()
    may_suspend? = peers_may_suspend?()

    readiness(expected, peers, dns?, may_suspend?, evidence(expected, peers, dns?, may_suspend?))
  end

  # The DNS lookup is made only where it decides between suspended and missing.
  defp evidence(expected, peers, true, true) when length(peers) < expected - 1,
    do:
      unconnected_running_peers(Application.get_env(:loopctl, :dns_cluster_query), node(), peers)

  defp evidence(_expected, _peers, _dns?, _may_suspend?), do: :unknown

  @doc """
  How many machines the clustering DNS query lists right now that this node is NOT connected
  to, or `:unknown` when the lookup fails. Resolved the way DNSCluster resolves it; this
  node's own address is not counted, and a listed address is connected when it is the host
  of a node in `peers` (a Fly node is named `<basename>@<6PN address>`). Compared address by
  address, not by count: with three machines a peer that is still connected but no longer
  listed must not hide a listed one that never connected.
  """
  @spec unconnected_running_peers(String.t() | nil, node(), [node()]) ::
          non_neg_integer() | :unknown
  def unconnected_running_peers(query, node, peers)
      when is_binary(query) and query != "" and is_list(peers) do
    own = address_of(node)
    connected = peers |> Enum.map(&address_of/1) |> MapSet.new()

    case resolver().lookup(query) do
      {:ok, addresses} ->
        addresses
        |> Enum.reject(&(&1 == own or MapSet.member?(connected, &1)))
        |> length()

      {:error, _reason} ->
        :unknown
    end
  end

  def unconnected_running_peers(_query, _node, _peers), do: :unknown

  defp address_of(node) do
    with [_name, host] <- String.split(Atom.to_string(node), "@", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)) do
      address
    else
      _ -> nil
    end
  end

  defp resolver,
    do:
      Application.get_env(:loopctl, :cluster_dns_resolver, Loopctl.ClusterReadiness.InetResolver)

  @doc """
  Whether this deployment's peers may be suspended (`CLUSTER_PEERS_MAY_SUSPEND`, read in
  `config/runtime.exs` through `parse_peers_may_suspend/1`). Off by default.
  """
  @spec peers_may_suspend?() :: boolean()
  def peers_may_suspend?,
    do: Application.get_env(:loopctl, :cluster_peers_may_suspend, false) == true

  @doc """
  Parses a `CLUSTER_PEERS_MAY_SUSPEND` value: `"true"` is true, anything else (unset
  included) is false, so a typo restores the alarm rather than silencing it.
  """
  @spec parse_peers_may_suspend(String.t() | nil) :: boolean()
  def parse_peers_may_suspend(value), do: value == "true"

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
            | :peers_may_be_suspended
            | :clustering_expected_dns_unconfigured
        }
  def readiness(expected_nodes, peers, dns_configured?),
    do: readiness(expected_nodes, peers, dns_configured?, false, :unknown)

  @doc """
  `readiness/3` for a deployment that has declared whether its peers may be suspended, with
  the DNS evidence `unconnected` (`unconnected_running_peers/3`: machines the clustering
  query lists that this node is not connected to, or `:unknown`).
  """
  @spec readiness(pos_integer(), [node()], boolean(), boolean(), non_neg_integer() | :unknown) ::
          %{
            dns_cluster_query_configured: boolean(),
            peers: non_neg_integer(),
            expected_nodes: pos_integer(),
            status:
              :single_node
              | :clustered
              | :expected_peers_missing
              | :peers_may_be_suspended
              | :clustering_expected_dns_unconfigured
          }
  def readiness(expected_nodes, peers, dns_configured?, may_suspend?, unconnected)
      when is_integer(expected_nodes) and is_list(peers) and is_boolean(dns_configured?) and
             is_boolean(may_suspend?) do
    peer_count = length(peers)

    %{
      dns_cluster_query_configured: dns_configured?,
      peers: peer_count,
      expected_nodes: expected_nodes,
      status:
        clustering_status(
          expected_nodes,
          peer_count,
          dns_configured?,
          suspension_explains?(may_suspend?, unconnected)
        )
    }
  end

  # Fewer peers than expected is explained by suspension only on a deployment that allows it
  # AND when every machine the DNS query lists is connected. No evidence, no excuse.
  defp suspension_explains?(true, unconnected) when is_integer(unconnected),
    do: unconnected == 0

  defp suspension_explains?(_may_suspend?, _unconnected), do: false

  # <= 1 expected node => single-node / not required (clustering never applies).
  defp clustering_status(expected_nodes, _peer_count, _dns?, _suspended?)
       when expected_nodes <= 1,
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
  defp clustering_status(expected_nodes, _peer_count, false, _suspended?) do
    if expected_nodes > @single_node_baseline,
      do: :clustering_expected_dns_unconfigured,
      else: :single_node
  end

  # Configured. Fewer peers than expected alarms unless suspension explains every missing
  # one (`suspension_explains?/2`): with `auto_stop_machines` a suspended peer is the normal
  # state, and a standing alarm teaches everyone to ignore the gauge — but a running peer
  # that failed to connect is exactly what the alarm is for.
  defp clustering_status(expected_nodes, peer_count, true, suspended?) do
    cond do
      peer_count >= expected_nodes - 1 -> :clustered
      suspended? -> :peers_may_be_suspended
      true -> :expected_peers_missing
    end
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
    expected = DbCapacity.expected_app_nodes()
    peers = peers()
    dns? = dns_cluster_query_configured?()
    may_suspend? = peers_may_suspend?()

    boot_check(
      node(),
      expected,
      peers,
      dns?,
      may_suspend?,
      evidence(expected, peers, dns?, may_suspend?)
    )
  end

  @doc """
  Both boot checks over injected inputs: the unroutable-node WARN
  (`warn_if_distribution_unroutable/2`), then the peers WARN
  (`warn_if_expected_peers_missing/5`). Returns `:ok` and never raises.
  """
  @spec boot_check(
          node(),
          pos_integer(),
          [node()],
          boolean(),
          boolean(),
          non_neg_integer() | :unknown
        ) ::
          :ok
  def boot_check(node, expected_nodes, peers, dns_configured?, may_suspend?, unconnected) do
    warn_if_distribution_unroutable(node, dns_configured?)

    warn_if_expected_peers_missing(
      expected_nodes,
      peers,
      dns_configured?,
      may_suspend?,
      unconnected
    )
  end

  @doc """
  Whether other nodes can reach `node` by name: it is distributed (not `nonode@nohost`)
  and its host is not a loopback address.
  """
  @spec distribution_routable?(node()) :: boolean()
  def distribution_routable?(node) when is_atom(node) do
    case String.split(Atom.to_string(node), "@", parts: 2) do
      [_name, host] when host not in ["nohost", "127.0.0.1", "::1", "localhost"] -> true
      _ -> false
    end
  end

  @doc """
  Pure boot check over an injected node name: WARNs when `DNS_CLUSTER_QUERY` is configured
  but `node` is unreachable by peers (`distribution_routable?/1`), and returns `:ok`. Logs
  no node name.
  """
  @spec warn_if_distribution_unroutable(node(), boolean()) :: :ok
  def warn_if_distribution_unroutable(node, dns_configured?)
      when is_atom(node) and is_boolean(dns_configured?) do
    if dns_configured? and not distribution_routable?(node) do
      Logger.warning(
        "Clustering readiness: DNS_CLUSTER_QUERY is configured but this node is " <>
          "#{if node == :nonode@nohost, do: "not distributed", else: "named on a loopback host"}" <>
          ", so no peer can ever connect to it and it runs UN-CLUSTERED. On Fly the node must " <>
          "be named after FLY_PRIVATE_IP with IPv6 distribution (rel/env.sh.eex): check " <>
          "RELEASE_NODE and ERL_AFLAGS in the machine's environment. This is a WARN, not a " <>
          "crash — a single node always boots."
      )
    end

    :ok
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
  def warn_if_expected_peers_missing(expected_nodes, peers, dns_configured?),
    do: warn_if_expected_peers_missing(expected_nodes, peers, dns_configured?, false, :unknown)

  @doc """
  `warn_if_expected_peers_missing/3`, for a deployment that has declared whether its peers
  may be suspended, with the DNS evidence of `unconnected_running_peers/3`.
  """
  @spec warn_if_expected_peers_missing(
          pos_integer(),
          [node()],
          boolean(),
          boolean(),
          non_neg_integer() | :unknown
        ) :: :ok
  def warn_if_expected_peers_missing(
        expected_nodes,
        peers,
        dns_configured?,
        may_suspend?,
        running
      )
      when is_integer(expected_nodes) and is_list(peers) and is_boolean(dns_configured?) and
             is_boolean(may_suspend?) do
    peer_count = length(peers)
    suspended? = suspension_explains?(may_suspend?, running)
    status = clustering_status(expected_nodes, peer_count, dns_configured?, suspended?)

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
            "DNS_CLUSTER_QUERY (fly.toml [env]) FIRST, then confirm the steady-state " <>
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
