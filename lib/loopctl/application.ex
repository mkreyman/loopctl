defmodule Loopctl.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Loopctl.Telemetry.SlowQueryLogger

  @impl true
  def start(_type, _args) do
    # US-29.2 (AC-29.2.10): fail fast if the promotion sweep window is not strictly
    # shorter than the session-turn TTL — otherwise SessionMemoryPruneWorker could
    # delete turns before they are promoted (silent golden-nugget loss).
    Loopctl.Memory.assert_promotion_ttl_invariant!()

    Loopctl.TenantKeys.init_cache()

    # US-27.4: uniform slow-query logging across all repos via one telemetry handler.
    SlowQueryLogger.attach()

    children = [
      LoopctlWeb.Telemetry,
      Loopctl.Vault,
      Loopctl.Repo,
      Loopctl.AdminRepo,
      Loopctl.HeavyReadRepo,
      {DNSCluster, query: Application.get_env(:loopctl, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Loopctl.PubSub},
      {Task.Supervisor, name: Loopctl.TaskSupervisor},
      # US-38.2: owns the public ETS table backing the throttled, PII-safe
      # rate-limiter fail-open logger, so a sustained limiter/DB outage emits a
      # bounded heartbeat per bucket-family instead of one warning per request
      # (and never writes client IPs into the logs). Node-local; pure ETS owner
      # with no other dependency.
      Loopctl.RateLimiter.FailOpenLog,
      {Oban, Application.fetch_env!(:loopctl, Oban)},
      # US-35.2 / US-38.3: supervised, CLUSTER-WIDE singleton (leadership via
      # :global, negotiated in init) that subscribes to the fixed audit-chain
      # firehose topic and debounce-enqueues one ComputeSthWorker job per tenant
      # that appends, making STH computation event-driven and activity-gated.
      # Every node keeps a live process, but exactly ONE (the leader) drains the
      # firehose cluster-wide; the rest stand by and fail over on leader death.
      # After PubSub (the leader subscribes in init) and Oban (it inserts jobs).
      # Purely additive — the per-minute cron is unchanged.
      Loopctl.AuditChain.SthEnqueuer,
      # US-37.5: owns the public ETS table holding the per-tenant in-flight HeavyRead
      # counters so a stable, long-lived owner survives the transient request/worker
      # process that incremented one. acquire/release BYPASS this owner (lock-free
      # :ets.update_counter on the hot read path); it exists only to own the table.
      # Node-local per-tenant, cost-weighted cap on the BYPASSRLS heavy-read pool so
      # one tenant's vector/analytic burst can't 503 every other tenant (GH #354).
      Loopctl.HeavyRead.TenantGate,
      # US-27.16: owns the ETS table tracking in-flight streaming-export slots so a
      # crashed exporter's slot is reclaimed (concurrency cap, AC-27.16.6).
      Loopctl.Knowledge.ExportConcurrency,
      # US-37.2: owns the ETS counter bounding concurrent OUTBOUND embedding calls
      # per node so a crashed acquirer's slot is reclaimed. Gates EVERY
      # generate_embedding entry point (interactive query path AND both Oban
      # embedding workers) via run_embedding_task/3, making the per-node ceiling
      # real (GH #352). Node-local; distributed coordination is Epic 38.
      Loopctl.Knowledge.EmbeddingConcurrency,
      # US-37.2: dedicated supervisor for the query-embedding tasks spawned by
      # run_embedding_task/3 (Task.Supervisor.async_nolink), so an embedding task
      # crash is isolated from the request/worker process (AC-37.2.5) with cleaner
      # isolation/telemetry than sharing the general Loopctl.TaskSupervisor.
      {Task.Supervisor, name: Loopctl.Knowledge.EmbeddingTaskSupervisor},
      # Owns the per-tenant embedding circuit-breaker ETS table so it has a STABLE,
      # long-lived owner (it would otherwise be created by a transient request/job/Task
      # and vanish when that process died — silently resetting the breaker).
      Loopctl.Knowledge.EmbeddingCircuitBreaker,
      # US-32.3: owns the ETS table caching resolved+decrypted per-tenant LLM
      # settings so a per-provider-call DB read + Cloak decrypt becomes a
      # per-change one. Stable owner survives the request/Task/Oban process that
      # populated an entry; invalidated on the settings write path.
      Loopctl.Llm.SettingsCache,
      # US-33.3: owns the ETS table caching resolved api_keys by key_hash so the
      # authenticated hot path becomes read-through — a per-request AdminRepo
      # SELECT becomes a per-change one. Stable owner survives the request/Task/
      # Oban process that populated an entry; every revoke/rotate/mutate writer
      # invalidates the key_hash entry (a bounded TTL backstops any missed path).
      # After PubSub + AdminRepo: it subscribes in init and its values preload
      # :tenant (custody_halted_at) for the CheckCustodyHalt plug (US-33.2).
      Loopctl.Auth.ApiKeyCache,
      # US-33.4: owns the ETS buffer that debounces the two per-request liveness
      # touch-writes (agents.last_seen_at, api_keys.last_used_at) off the auth
      # hot path — the request records into ETS and a periodic flusher writes the
      # buffered maxima in one batched, monotonic UPDATE. After AdminRepo (it
      # writes via AdminRepo at flush); stable owner survives the request/Task/
      # Oban process that recorded a touch.
      Loopctl.TouchBuffer,
      LoopctlWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Loopctl.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Prime the SystemConfig :persistent_term cache from the DB now that the repos
    # are started, so the ingestion/extraction hot path reads live values from the
    # first request. refresh/0 is rescue-wrapped (a DB blip logs and no-ops), so a
    # failed prime NEVER blocks boot — the in-code defaults simply apply until the
    # per-minute refresh cron succeeds.
    Loopctl.SystemConfig.refresh()

    # US-27.11 (AC-27.11.5): warn if the actual configured pools would exceed the live
    # DB max_connections at the expected node count. Prod only (dev/test pools differ),
    # log-only, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod, do: Loopctl.DbCapacity.warn_if_over_budget()

    # US-38.1 (AC-38.1.2): when a DISTINCT read replica is configured, FAIL LOUD at boot if it
    # is unreachable — a supervised Ecto pool otherwise boots green and 500s every heavy read
    # at query time. No-op unless REPLICA_DATABASE_URL points at a distinct DSN. Prod only;
    # RAISES (aborts boot) on an unreachable replica, by design.
    if Application.get_env(:loopctl, :env) == :prod,
      do: Loopctl.ReplicaReadiness.assert_reachable!()

    # US-38.1: replica half of the connection-budget check — when a distinct replica is
    # configured, warn (log only) if the offloaded heavy-read pool would exhaust the REPLICA's
    # own max_connections. No-op without a replica. Prod only, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod,
      do: Loopctl.DbCapacity.warn_if_replica_over_budget()

    # US-27.9a: warn if a CONCURRENTLY-built critical index (e.g. the article keyset
    # index) is missing/INVALID after an interrupted build — silent Seq-Scan degradation
    # otherwise. Prod only, log + telemetry, never blocks boot.
    if Application.get_env(:loopctl, :env) == :prod,
      do: Loopctl.IndexHealth.warn_if_invalid_indexes()

    # US-38.3 (AC-38.3.3): clustering-readiness gate. When the app is told to expect
    # peers (EXPECTED_APP_NODES > 1) but Node.list/0 is empty, WARN that this node is
    # running un-clustered (node-local PubSub) so a machine-count bump can't silently
    # run un-clustered. WARN + runbook, NEVER a crash — a single node always boots.
    # Prod only, rescue-wrapped, mirroring DbCapacity.warn_if_over_budget/0.
    if Application.get_env(:loopctl, :env) == :prod,
      do: Loopctl.ClusterReadiness.warn_if_expected_peers_missing()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LoopctlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
