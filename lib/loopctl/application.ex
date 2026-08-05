defmodule Loopctl.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Loopctl.Telemetry.IngestionWriteStats
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

    # PR B2: fold every KB article write OUTCOME into the durable
    # `ingestion_write_stats` rollup (the no-persist / high-rejection-rate detector's
    # data source). Self-rescuing, so a dropped rollup increment never affects the
    # write it observes.
    IngestionWriteStats.attach()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Loopctl.Supervisor]
    result = Supervisor.start_link(children(), opts)

    # ONLY on a successful start: these checks need the tree RUNNING, and one of them
    # (ReplicaReadiness) raises by design. On a failed start every already-started child
    # has been torn down, so running them there replaces the real
    # `{:error, {:shutdown, {:failed_to_start_child, ...}}}` — the diagnosis — with an
    # unrelated crash from a check querying a repo that no longer exists.
    case result do
      {:ok, _pid} -> post_boot_checks()
      _error -> :ok
    end

    result
  end

  # The supervision-tree child list, extracted so its ORDER can be asserted
  # statically (GH #588) without booting anything — a supervisor starts children
  # synchronously in list order, so the order in this list IS the guarantee.
  @doc false
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    [
      LoopctlWeb.Telemetry,
      Loopctl.Vault,
      Loopctl.Repo,
      Loopctl.AdminRepo,
      Loopctl.HeavyReadRepo,
      # GH #588: primes the SystemConfig :persistent_term cache from the DB
      # SYNCHRONOUSLY (inside its start_link/1, then returns :ignore), so the
      # cache is authoritative before ANY consumer starts. Placement is the whole
      # point: a supervisor starts children in list order, so sitting AFTER
      # Loopctl.AdminRepo (which refresh/0 reads through) and BEFORE {Oban, ...}
      # and LoopctlWeb.Endpoint is what makes "primed before work is accepted" a
      # guarantee rather than a race. This replaces a post-`start_link` prime,
      # under which both consumers served requests against an EMPTY cache for a
      # startup window — and a miss returns the caller's in-code default, which
      # for the embeddings read-routing flag ("embedding_side_table_reads") is
      # the RETIRED legacy `articles.embedding` column. Every boot therefore
      # silently reverted the completed cutover on semantic search, suggest-links
      # and the novelty gate. Never make this a Task child or a
      # handle_continue/2: both return to the supervisor immediately and
      # reproduce the race. A failed prime is loud (log + telemetry) but NEVER
      # blocks boot — the in-code defaults apply until the per-minute
      # SystemConfigRefreshWorker succeeds.
      Loopctl.SystemConfig.CachePrimer,
      {DNSCluster, query: Application.get_env(:loopctl, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Loopctl.PubSub},
      {Task.Supervisor, name: Loopctl.TaskSupervisor},
      # PR B2: BOUNDED supervisor for the fire-and-forget `ingestion_write_stats`
      # rollup upserts spawned by `Loopctl.Telemetry.IngestionWriteStats`. The
      # high_reject_rate detector's trigger condition is a client HAMMERING create in a
      # retry loop (a title_conflict/validation storm) — i.e. exactly when write volume
      # spikes — so an UNBOUNDED per-write task fan-out would flood the small BYPASSRLS
      # AdminRepo pool (also serving the rate limiter + auth) precisely during the
      # incident this feature detects, amplifying the outage. `max_children` caps the
      # fan-out: over the cap `start_child` returns `{:error, :max_children}` and the
      # increment is DROPPED (best-effort analytics, never blocks/fails the observed
      # write). Separate from the general `Loopctl.TaskSupervisor` so this backpressure
      # is isolated, mirroring `Loopctl.Memory.RecallBumpTaskSupervisor`.
      #
      # The cap is sized to the AdminRepo pool (ADMIN_POOL_SIZE, default 3), NOT set to
      # a large fan-out: each task issues one AdminRepo checkout, so a cap far above the
      # pool merely oversubscribes the 3-conn pool during a storm (queueing checkouts
      # past `queue_target`/`queue_interval` and starving the co-tenant rate-limiter/auth
      # upserts). A small multiple of the pool (default 10) allows brief overlap while
      # keeping concurrent checkout demand bounded to roughly the pool depth — excess
      # increments drop rather than pile onto the pool. Under normal low-frequency writes
      # tasks complete in microseconds, so the cap is never approached.
      {Task.Supervisor,
       name: Loopctl.Telemetry.IngestionWriteStatsTaskSupervisor,
       max_children: Application.get_env(:loopctl, :ingestion_write_stats_max_tasks, 10)},
      # #411 Gap 3: owns the public ETS table that pre-filters recall-count hotness
      # bumps already inside their per-memory cooldown window, so an idle-window
      # recall issues ZERO background tasks and ZERO DB writes (the DB-side
      # `WHERE last_recalled_at < cutoff` stays the source of truth). Node-local
      # pure ETS owner; survives the transient recall/task process that wrote to it.
      Loopctl.Memory.RecallBumpCache,
      # #411 Gap 3: BOUNDED supervisor for the fire-and-forget recall-count bump
      # tasks. `max_children` caps the fan-out so a burst of healthy recalls cannot
      # spawn an unbounded set of background writes that starve the write pool —
      # over the cap `start_child` returns `{:error, :max_children}` and the bump is
      # dropped (best-effort analytics, never fails the recall). Separate from the
      # general `Loopctl.TaskSupervisor` so bump backpressure is isolated.
      {Task.Supervisor,
       name: Loopctl.Memory.RecallBumpTaskSupervisor,
       max_children: Application.get_env(:loopctl, :memory_recall_bump_max_tasks, 200)},
      # US-38.2: owns the public ETS table backing the throttled, PII-safe
      # rate-limiter fail-open logger, so a sustained limiter/DB outage emits a
      # bounded heartbeat per bucket-family instead of one warning per request
      # (and never writes client IPs into the logs). Node-local; pure ETS owner
      # with no other dependency.
      Loopctl.RateLimiter.FailOpenLog,
      Loopctl.RateLimiter.FailOpenBackstop,
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
      # US-41.1 (review): owns the ETS table memoizing the per-(tenant, dimension)
      # semantic-search disclosure meta, so the steady-state system-corpus anti-join
      # and the two re-embed existence probes are not paid on EVERY semantic search.
      Loopctl.Embeddings.DisclosureCache,
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
      # US-41.4 (AC-41.4.12): owns the ETS table holding resolved+classified
      # egress pins, keyed (tenant_id, scope, host). A NAMED SUPERVISED owner —
      # not a bare TTL — because it re-resolves and re-pins BEFORE expiry with
      # jitter; a TTL-expiry cliff would be a scheduled fleet-wide outage in
      # which every local_only tenant hard-refuses at once, and a privacy control
      # whose steady state is an outage gets disabled in production.
      Loopctl.Egress.PinCache,
      # US-41.4 (AC-41.4.6): owns the ETS table that debounces blocked-decision
      # WRITES off the refusal path. Bounding the ROW count is not enough — one
      # upsert per blocked call still serializes thousands of row-lock round-trips
      # a minute on the 3-connection AdminRepo pool the guard's own marking lookup
      # needs. After AdminRepo (it writes via AdminRepo at flush).
      Loopctl.Egress.BlockedBuffer,
      # US-41.7 (AC-41.7.4): bounded memo for merkle inclusion proofs, so the
      # PUBLIC, unauthenticated proof endpoint cannot be turned into an O(chain
      # length) CPU amplifier by repeating the same request.
      Loopctl.AuditChain.ProofCache,
      LoopctlWeb.Endpoint
    ]
  end

  # Boot-time observability checks that need the tree running. Log/telemetry only,
  # with the single deliberate exception noted below.
  defp post_boot_checks do
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

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LoopctlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
