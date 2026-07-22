import Config

# Test concurrency + pool sizing — BOUNDED, and the two MUST move together.
#
# Three repos (Repo, AdminRepo, HeavyReadRepo) each open `pool_size` connections
# EAGERLY at boot, so the suite's floor demand is 3 * pool_size before a single
# test runs. Sizing that purely off the core count overruns a stock Postgres
# `max_connections` (100) on a high-core dev box: 24 cores * 2 * 3 repos = 144,
# which fails as `DBConnection.ConnectionError ... queue_timeout` on sandbox
# checkout — a full DB that reads like a missing one. Capping keeps the floor at
# 3 * 16 = 48 on every machine (mac-mini, blockit, beelink) and in CI, leaving
# room for a second Elixir app sharing the same local Postgres.
#
# `max_cases` is derived from the SAME number on purpose: the pool must never be
# smaller than the count of concurrently running async tests, or the suite
# deadlocks on checkout from the other direction. Change one, change both.
test_concurrency = min(System.schedulers_online(), 8)
test_pool_size = test_concurrency * 2

config :ex_unit, max_cases: test_concurrency

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :loopctl, Loopctl.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loopctl_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_pool_size

# AdminRepo — same database, sandbox mode for tests
config :loopctl, Loopctl.AdminRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loopctl_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_pool_size,
  # Scale tests seed ~80k rows under Sandbox.unboxed_run/2, which can exceed the
  # default 60s ownership timeout (the seed takes >2 min) → "owner process crashed".
  # Allow the unboxed connection to be held long enough for the prod-floor seed.
  ownership_timeout: :timer.minutes(30)

# HeavyReadRepo (US-27.11) — sandbox mode for tests. Nothing in the default suite routes
# heavy DATA reads here — `:heavy_read_repo` below points heavy reads at AdminRepo so they
# share the sandbox connection fixtures insert through; only the dedicated HeavyReadRepo
# pool tests touch this repo directly.
#
# NO `parameters: [statement_timeout: ...]` here — the test config must MIRROR prod, which
# CANNOT carry that startup parameter: Fly MPG fronts Postgres with pgbouncer, which rejects
# a `statement_timeout` startup parameter with `08P01 unsupported startup parameter` and
# crash-loops the whole pool (the US-27.13 outage). The original param "passed" in CI only
# because the suite connects to DIRECT Postgres (which accepts it) — the exact false
# confidence that hid the bug. The server-side timeout is now applied per-read via SET LOCAL;
# config_pgbouncer_safe_parameters_test.exs blocks any repo from re-adding an incompatible key.
config :loopctl, Loopctl.HeavyReadRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loopctl_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_pool_size,
  ownership_timeout: :timer.minutes(30)

# The pool-wide DEFAULT server-side statement_timeout (US-27.13), applied via SET LOCAL on
# the heavy-read path (HeavyRead.opts/1). Low (250ms) in test so the fast-fire mechanism
# tests stay sub-second.
config :loopctl, :heavy_read_statement_timeout_ms, 250

# US-33.4: set the touch-buffer flush interval very high in tests so the
# app-tree singleton NEVER auto-flushes during a run — its timer would fire in
# the GenServer process without a checked-out sandbox connection and could drain
# other async tests' buffered entries. Tests drive an isolated per-test buffer
# instance and flush it explicitly in-process (which owns the sandbox
# connection); integration tests assert on the buffer contents directly.
config :loopctl, Loopctl.TouchBuffer, flush_interval_ms: :timer.hours(1)

# Keep the L3 local test runner DISABLED in tests (it clones repos + runs
# `mix test` on untrusted code). TestRunner's tests exercise the disabled path
# and the validation-rejection paths WITHOUT ever cloning a real repo; input
# validation runs before this gate, so validation-rejection is asserted
# independently of the flag.
config :loopctl, :enable_local_test_runner, false

# DI (US-27.11): route Loopctl.HeavyRead's heavy reads to AdminRepo in tests, so
# they see the same sandbox transaction that fixtures write to. Prod/dev default to
# the dedicated Loopctl.HeavyReadRepo pool.
#
# CAUTION (US-27.13 — SET LOCAL scoping under Sandbox): prefer asserting statement_timeout
# behavior against the dedicated `Loopctl.HeavyReadRepo` pool directly (as
# heavy_read_repo_test.exs / heavy_read_pool_isolation_test.exs do), NOT the AdminRepo-routed
# `HeavyRead.all/one` path. Under Sandbox the routed `transaction/2` runs as a SAVEPOINT
# inside the test's outer transaction, and `SET LOCAL` is scoped to the TOP-LEVEL
# transaction. A CANCELLATION is self-cleaning (the query raises, the savepoint rolls back,
# and the SET LOCAL is undone — so `heavy_read_statement_timeout_test.exs` is stable). The
# real hazard is a SUCCESSFUL low-timeout routed read: its savepoint COMMITS, so the SET
# LOCAL persists to the enclosing sandbox transaction and could spuriously cancel a later
# query in the SAME test. Keep timeout assertions on the dedicated pool to avoid that.
config :loopctl, :heavy_read_repo, Loopctl.AdminRepo

# Per-endpoint statement_timeout overrides (HeavyRead.opts/1). An endpoint listed here
# uses its own SET LOCAL statement_timeout instead of the aggressive 250ms pool-wide
# default (`:heavy_read_statement_timeout_ms` above). Two distinct reasons an endpoint
# appears here:
#
#   * :suggested_links (US-27.4, TC-27.4.1) — a generous 5s so the integration test's
#     real query never times out; the timeout MECHANISM is proven elsewhere by tests
#     that pass an EXPLICIT low per-call `statement_timeout` (heavy_read_statement_timeout_test.exs,
#     suggest_links_controller "override -> real 57014 -> 504") and by :semantic_search
#     inheriting the 250ms default (slow_query_logger_test.exs).
#
#   * :change_feed — the keyset change-feed read behind `GET /api/v1/changes`
#     (Audit.list_changes/3 -> HeavyRead.opts(:change_feed)). On the small sandbox
#     dataset this read is sub-millisecond, but under 24-way parallel DB contention it
#     intermittently exceeded the 250ms default and 57014'd (HTTP 504), flaking
#     INCIDENTAL callers of GET /changes (update_last_seen_test.exs and friends) that
#     don't intend to test the timeout at all. 5s is generous enough to never trip under
#     contention yet still finite (prod-scale plan/index is guarded separately by
#     by_source_change_feed_plan_scale_test.exs / keyset_plan_scale_test.exs). No test
#     asserts a :change_feed timeout, so this override cannot mask a real one.
config :loopctl, :heavy_read_statement_timeout_overrides, %{
  suggested_links: 5_000,
  change_feed: 5_000,
  # Epic 28 (#179): the per-tenant LLM usage summary (GET /knowledge/llm-usage)
  # routes through HeavyRead. On the small sandbox dataset it's sub-ms, but a
  # generous 5s override keeps it from tripping the aggressive 250ms pool default
  # under parallel contention (same rationale as :change_feed). No test asserts an
  # :llm_usage timeout, so this cannot mask a real one.
  llm_usage: 5_000,
  # distant_pairs (esp. the bridge branch) can legitimately run ~1s at the :scale_nightly
  # 80k corpus — well above the 250ms pool default — so give it generous headroom here or the
  # server-side timeout would cancel the scale bridge case before it completes. The <2s
  # Theme-2 target is asserted SEPARATELY (wall-clock) in distant_pairs_novelty_scale_test.exs;
  # prod carries the tighter 4s backstop (config/config.exs).
  distant_pairs: 5_000,
  distant_pairs_bridge: 5_000,
  # US-28.2: the agent-memory HNSW recall (Loopctl.Memory.recall/2 -> all_memory/4).
  # Sub-ms on the small sandbox dataset, but a generous 5s override keeps it off the
  # aggressive 250ms pool default under parallel contention AND avoids a successful
  # low-timeout SET LOCAL persisting into the enclosing sandbox transaction. No test
  # asserts a :memory_recall timeout, so this cannot mask a real one.
  memory_recall: 5_000,
  # US-34.6: the GET /knowledge/ingestion-jobs COUNT + list over the Oban-owned
  # oban_jobs table (Loopctl.HeavyRead.opts(:ingestion_jobs)). Sub-ms on the small
  # sandbox dataset, but a generous 5s override keeps it off the aggressive 250ms
  # pool default under parallel contention AND avoids a successful low-timeout SET
  # LOCAL persisting into the enclosing sandbox transaction (same rationale as
  # :llm_usage/:memory_recall). No test asserts an :ingestion_jobs timeout, so this
  # cannot mask a real one.
  ingestion_jobs: 5_000,
  # US-35.1: the incremental-STH tail read and the keyset-paged full-rebuild read
  # over audit_chain (Loopctl.HeavyRead.opts(:sth_incremental)). A few-hundred-row
  # indexed range scan is sub-ms on the sandbox, but a generous 5s override keeps it
  # off the aggressive 250ms pool default under parallel contention (same rationale
  # as the endpoints above). No test asserts a :sth_incremental timeout, so this
  # cannot mask a real one.
  sth_incremental: 5_000
}

# US-27.6b: the over-fetch pool sizing knobs (`Loopctl.Knowledge.VectorSearch.pool_size/2`).
# In the DEFAULT async suite we shrink floor/cap to 6 so the under-fill detection can be
# exercised deterministically with a handful of seeded rows (filling a 6-row pool needs ~6
# articles, not 100). 6 is kept >= the `k=5` used across the existing fast tests so the
# floor-at-k invariant doesn't perturb their `pool == max_pool()` assertions. The SCALE
# gate (`SCALE_NIGHTLY`/`SCALE_TESTS`) leaves the PROD defaults (factor 5 / floor 100 / cap
# 500) so the dense-hub + cost-bound scale tests stay prod-shaped. This is config-based DI
# — NO Application.put_env in any test body; the unit `pool_size/2` tests pass explicit
# knob args, so they are independent of this value.
unless System.get_env("SCALE_NIGHTLY") || System.get_env("SCALE_TESTS") do
  config :loopctl, :vector_pool_factor, 5
  config :loopctl, :vector_pool_floor, 6
  config :loopctl, :max_vector_pool, 6

  # US-27.7a `search_semantic` relevance-pool knobs, shrunk so the deep-offset /
  # `pool_capped` truncation signal is exercisable with a handful of seeded rows (prod
  # floor/cap are 200/1000). Existing semantic tests seed ≤ cap rows, so they are
  # unaffected. The SCALE gate keeps the prod defaults. Config-based DI — no put_env.
  config :loopctl, :semantic_result_pool_floor, 2
  config :loopctl, :semantic_result_pool_cap, 5

  # US-27.16: the streaming-export concurrency cap (`Loopctl.Knowledge.ExportConcurrency`).
  # The GLOBAL cap (`:export_max_concurrent_global`, prod default 2 — sized to the heavy-read
  # pool's export reservation) is a SINGLE VM-wide ETS counter shared by EVERY async test that
  # makes a real export request. In the DEFAULT suite (max_cases ~24) three-plus incidental
  # OKF/Obsidian export tests — each its OWN tenant, so the PER-TENANT cap of 1 is never the
  # constraint — run concurrently and contend on that one global counter of 2, so the 3rd+
  # intermittently got a spurious 429 instead of 200 (a shared-global-state flake, NOT a real
  # over-cap). Raise the GLOBAL cap well above max_cases so incidental parallel exports never
  # collide; the PER-TENANT cap stays at the prod default (1) because it is NEVER the incidental
  # constraint (distinct tenants) and the controller's dedicated 429 test saturates it directly.
  #
  # This cannot mask a real limiter regression: the DEDICATED limit tests set their OWN explicit
  # LOW caps and so are independent of this value — `export_concurrency_test.exs` calls
  # `ExportConcurrency.acquire/3` with fixed caps, `knowledge_export_controller_test.exs` trips
  # the per-tenant cap (unchanged at 1), and the nightly `streaming_export_scale_test.exs`
  # (TC-27.16.5) runs OUTSIDE this SCALE gate so it keeps the prod default (2) and still proves
  # the cap refuses over-budget exports.
  config :loopctl, :export_max_concurrent_global, 64
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :loopctl, LoopctlWeb.Endpoint,
  # `websocket_options` caps a reassembled multi-frame websocket message (Bandit
  # server-level backstop; see runtime.exs). Asserted by a regression test so a
  # future edit that drops it fails CI.
  http: [
    ip: {127, 0, 0, 1},
    port: 4002,
    websocket_options: [max_fragmented_message_size: 64_000]
  ],
  secret_key_base: "QO3UeePU6EXaPNWZRMdH5lL+t+XQNelN9GHOJKhFgp8FEtjlvGzWWXoMiQI1EOE3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Narrow capture-silence monitoring to `session_log` in tests so specs can assert
# that OTHER source_types are not flagged (the prod default is `:all`). The `:all`
# behavior is covered by passing explicit config to `IngestionHealth.detect/1`.
config :loopctl, :ingestion_health,
  monitored_source_types: ["session_log"],
  established_threshold: 5,
  staleness_threshold_hours: 72,
  establishment_window_hours: 720,
  # PR B2 reject-rate detector pins (deterministic thresholds for specs).
  reject_rate_threshold: 0.5,
  min_attempts: 10,
  reject_window_days: 7

# Run the write-outcome rollup upsert INLINE in test (prod dispatches it to a
# supervised task): inline shares the emitting test process's sandboxed connection, so
# the rollup row is readable back synchronously in specs.
config :loopctl, Loopctl.Telemetry.IngestionWriteStats, async: false

# Use simple formatter in test (override JSON default from config.exs).
# The template prints only level + message (custom metadata is asserted via the
# message string in tests), but declare `metadata: :all` so Credo's
# MissedMetadataKeyInLoggerConfig check knows arbitrary structured keys
# (sqlstate, mapped_code, … — US-27.3) are permitted in this env.
config :logger, :default_handler,
  formatter: {:logger_formatter, %{template: [:level, ": ", :message, "\n"]}}

config :logger, :default_formatter,
  metadata: [
    :request_id,
    :tenant_id,
    :remote_ip,
    :sqlstate,
    :mapped_code,
    :controller,
    :action,
    :pg_message,
    :duration_ms,
    :repo,
    :source,
    :endpoint
  ]

# Oban: inline testing mode (jobs execute synchronously in tests)
config :loopctl, Oban, testing: :inline

# US-35.2: keep the boot SthEnqueuer singleton from subscribing to the audit-chain
# firehose in the test suite. It runs in the app supervision tree (not a per-test
# sandbox owner), so reacting to a test's `AuditChain.append/1` would fire an
# `Oban.insert` without an owned Sandbox connection. Tests that exercise the live
# subscriber start their OWN named instance with `subscribe: true`; production
# leaves this unset (defaults true) so the tree child subscribes normally.
config :loopctl, :sth_enqueuer_subscribe, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Cloak Vault — static test key (32 bytes, base64-encoded)
config :loopctl, Loopctl.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("tv9k+u3uqigJly2BdAZTVhtkB5uRBNObattywOn5KCE="),
      iv_length: 12
    }
  ]

# Enable dev routes (openapi, swaggerui) in test so route compilation succeeds
config :loopctl, dev_routes: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# DI: Use mock health checker in tests
config :loopctl, :health_checker, Loopctl.MockHealthChecker

# US-32.4: scale-alerts config-guard DI (Loopctl.HealthCheck.Default's degraded-branch
# coverage). Default stub in DataCase delegates to the real config_status/0.
config :loopctl, :scale_alerts_config_checker, Loopctl.MockScaleAlertsConfigChecker

# US-34.2: Oban orphan-count DI (Loopctl.HealthCheck.Default's oban_orphans
# degraded-branch coverage). Default stub in DataCase delegates to the real
# ScaleMetrics.count_oban_executing_orphans/0.
config :loopctl, :oban_orphan_count_checker, Loopctl.MockObanOrphanCountChecker

# US-36.3: batch-ingest backlog admission gate's count DI seam. Default stub in
# DataCase.stub_all_defaults/0 delegates to the real FairShare.in_flight_count/2;
# the fail-open test overrides it to raise.
config :loopctl, :ingestion_backlog_counter, Loopctl.MockBacklogCounter

# DI: Use mock rate limiter in tests
config :loopctl, :rate_limiter, Loopctl.MockRateLimiter

# Trusted-proxy range for the shared Loopctl.RemoteIp resolver in tests. Headers
# are chosen per-call (singleton fly-client-ip / x-forwarded-for), so only
# :proxies is configured here.
config :loopctl, :remote_ip_opts, proxies: ~w[198.51.100.0/24]

# DI: Use mock clock in tests
config :loopctl, :clock, Loopctl.MockClock

# DI: Use mock cost rollup in tests
config :loopctl, :cost_rollup, Loopctl.MockCostRollup

# DI: Use mock token archival in tests
config :loopctl, :token_archival, Loopctl.MockTokenArchival

# US-41.1: disable the disclosure-meta memoization in tests so a test that changes
# the system-corpus / re-embed state observes it on the very next search (the cache
# is a hot-path optimization, not behavior).
config :loopctl, :embedding_disclosure_cache_ms, 0

# DI: Use mock embedding client in tests
config :loopctl, :embedding_client, Loopctl.MockEmbeddingClient

# US-37.2: DI seam for the per-node outbound-embedding concurrency gate. In :test it
# resolves to the mock so a saturation test can force {:error, :rate_limited_local}
# deterministically; the DataCase default stub returns :ok/:ok so every existing
# search test is unaffected. The REAL Loopctl.Knowledge.EmbeddingConcurrency GenServer
# is unit-tested directly (embedding_concurrency_test.exs), bypassing this seam.
config :loopctl, :embedding_concurrency, Loopctl.MockEmbeddingConcurrency

# US-37.2: high suite-wide default for the embedding concurrency cap so incidental
# parallel interactive searches in the async suite never collide on the shared,
# VM-wide global counter (the export-cap precedent at :export_max_concurrent_global).
# The gate's OWN unit test sets explicit LOW caps via acquire/3, independent of
# these values; the search-path saturation test uses the DI mock above, not the real
# counter. Production uses the config.exs default (10), live-tunable via SystemConfig.
config :loopctl, :embedding_max_concurrent, 64

# US-37.2 per-tenant sub-cap: high suite-wide default for the SAME reason as the
# global cap above — incidental parallel searches (per tenant) must not collide on
# the shared, VM-wide per-tenant counters. The gate's unit test passes an explicit
# LOW per-tenant cap via acquire/3. Production uses the config.exs default (6).
config :loopctl, :embedding_max_concurrent_per_tenant, 64

# US-37.5: suite-wide default for the per-tenant in-flight HeavyRead cap (K). Set to
# the clamp CEILING (`pool - 1`, pool = Loopctl.DbCapacity.heavy_read_budget().pool = 8),
# the highest value `TenantGate.cap/0`'s `clamp_cap/1` admits — so the gate wired into
# Loopctl.HeavyRead.all/one/all_memory stays as permissive as possible for incidental
# heavy reads across the async suite (each test uses a UNIQUE fixture tenant, so
# per-tenant, VM-wide counters do not collide across tests; a single test would need
# >7 units of concurrent SAME-tenant heavy-read weight to shed). A former sentinel
# (100_000) is no longer usable: `cap/0` now clamps any out-of-range value into
# `[heavy_weight, pool - 1]` and LOGS on clamp, so an out-of-range test cap would spam
# warnings on every heavy read AND still resolve to 7. The gate's OWN unit test
# (tenant_gate_test.exs) passes explicit LOW caps to acquire/4, independent of this
# value. Production uses Loopctl.DbCapacity.heavy_read_tenant_slice/0 (4), live-tunable
# via the "heavy_read_tenant_cap" SystemConfig key.
config :loopctl, :heavy_read_tenant_cap, 7

# US-28.2: a small per-(tenant, subject) long-term memory cap so the quota path
# (`{:error, :quota_exceeded}`) is testable without inserting tens of thousands of
# rows. Kept above the largest pagination test (25 rows) so that test stays under
# the cap. Production uses the 10_000 default.
config :loopctl, :max_long_term_memories_per_subject, 30

# US-30.1: a small per-tenant entity-definition cap so the limit path
# (`{:error, :entity_limit}`) is testable without inserting 50 rows.
config :loopctl, :max_entity_definitions_per_tenant, 3

# US-30.3: a small Context Retriever max page size so the pagination-cap path is
# testable (TC-30.3.5) without seeding 100+ rows.
config :loopctl, :context_retriever_max_page_size, 5

# US-30.3: a small max pagination offset so the offset-cap path is testable
# without a deep-offset scan.
config :loopctl, :context_retriever_max_offset, 50

# US-30.3: Context-Retriever audit writer DI. Resolves to a Mox mock whose
# DataCase default stub delegates to the real Loopctl.Audit — so existing
# executor tests write genuine audit rows, while the fail-closed test overrides
# it to force an {:error, _} and assert run/3 returns {:error, :audit_failed}.
config :loopctl, :context_retriever_audit, Loopctl.ContextRetriever.MockAudit

# DI: Use mock knowledge extractor in tests
config :loopctl, :knowledge_extractor, Loopctl.MockExtractor

# DI: Use mock content extractor in tests
config :loopctl, :content_extractor, Loopctl.MockContentExtractor

# DI: Use mock memory-promotion LLM in tests (Epic 29). A small max_candidates so
# the top-N cap is exercised with a handful of candidates. Config-based DI — no
# Application.put_env in any test body.
config :loopctl, :promoter_llm, Loopctl.MockPromoterLLM
config :loopctl, :memory_promotion_confidence_threshold, 0.5
config :loopctl, :memory_promotion_max_candidates, 3

# US-29.2 auto-promotion tunables. Small caps so the per-tenant compiles/hour budget
# and the sweep per-tick cap are exercised without seeding hundreds of rows. The TTL
# invariant (sweep window < session TTL) holds: 600 < 3600 (defaults from config.exs).
config :loopctl, :memory_promotion_compiles_per_hour, 5
config :loopctl, :memory_promotion_sweep_max_per_tick, 5
config :loopctl, :memory_promotion_near_dup_threshold, 0.9

# DI: Use mock category classifier in tests
config :loopctl, :category_classifier, Loopctl.MockCategoryClassifier

# DI: Use mock WebAuthn adapter in tests
config :loopctl, :webauthn_adapter, Loopctl.MockWebAuthn

# Full-content (include_body) byte budget — small in tests so the byte-budget
# truncation/continuation behavior can be exercised with a few small bodies
# instead of ~5 MB of fixtures (production default is 5_000_000).
config :loopctl, :full_content_byte_budget, 100_000

# Graph-traversal node cap — small in tests so the `truncated` cap behavior can
# be exercised with ~11 nodes instead of 100+ (production default is 100).
config :loopctl, :max_graph_nodes, 10

# Progressive-disclosure caps (US-31.3) — small in tests so the top-K/hub caps
# can be exercised with a handful of fixtures instead of production-scale
# corpora (production defaults are 10 and 5 respectively).
config :loopctl, :progressive_top_k, 3
config :loopctl, :progressive_min_hub_relates_to, 3

# Distant-pairs candidate caps — small in the DEFAULT async suite so the O(candidates²)
# sample cap (and the bridge branch's SMALLER cap) can be exercised with a handful of articles
# instead of 1000+/500. The bridge cap (10) is kept < the general cap (25) so the bridge-branch
# invariant genuinely binds in the unit test. The SCALE gate (SCALE_NIGHTLY/SCALE_TESTS) leaves
# the PROD defaults (general 1000, bridge 500) so the :scale_nightly distant_pairs cases are
# prod-shaped — the bridge latency proof needs the REAL 500 cap (a small cap would make it
# trivially fast and prove nothing). Mirrors the vector_pool_* pattern above. Config-based DI —
# NO Application.put_env in any test body.
unless System.get_env("SCALE_NIGHTLY") || System.get_env("SCALE_TESTS") do
  config :loopctl, :max_pair_candidates, 25
  config :loopctl, :max_bridge_pair_candidates, 10
end

# US-27.12: low frozen-set bound so the oversized re-confirm-on-drift bulk-delete
# path is exercisable with a handful of rows instead of 1001 (production default
# is 1000). Config-based DI — no Application.put_env in tests.
config :loopctl, :bulk_delete_frozen_max, 3

# US-27.16: small streaming-export tunables so tests exercise the multi-page keyset
# walk, the per-article link cap, and the concurrency cap cheaply. Config-based DI
# (no Application.put_env in tests).
# - chunk_size 3: a handful of articles spans several keyset pages (proves the walk
#   releases the connection between pages and that max in-flight ≤ chunk_size).
# - max_links_per_article 5: a "dense hub" of >5 links is bounded with ~6 neighbors
#   instead of 100+.
# (The `:export_max_concurrent_global` cap is raised in the SCALE-gated block above, so
# it is NOT overridden here — the nightly scale leg keeps the prod default so TC-27.16.5
# can still prove the cap refuses over-budget exports.)
config :loopctl, :export_chunk_size, 3
config :loopctl, :export_max_links_per_article, 5

# US-27.16 (#3): small decompression-bomb caps so the bomb-defense test runs cheaply
# — a ~1KB gzip that inflates past these is rejected without materializing it.
config :loopctl, :import_export_max_compressed_bytes, 1_000_000
config :loopctl, :import_export_max_decompressed_bytes, 5_000_000

# US-27.16: small cap so the `?format=json` buffered-export 413 (over-cap) is
# testable cheaply. Set to 2 so a 3-article corpus trips it. The OKF round-trip /
# export CONTEXT tests that legitimately build larger bundles pass an explicit
# `build_bundle(t, max_articles: ...)` override, so they are unaffected.
config :loopctl, :okf_max_buffered_export_articles, 2

# WebAuthn relying party — test fixtures expect localhost
config :loopctl, :webauthn,
  rp_id: "localhost",
  rp_name: "loopctl (test)",
  origin: "http://localhost:4002",
  user_verification: "preferred"

# DI: Use mock secrets adapter in tests
config :loopctl, :secrets_adapter, Loopctl.MockSecrets

# DI (US-27.3): suggested-links executor. The default stub in
# DataCase.stub_all_defaults/0 delegates to the real Loopctl.Knowledge, so
# existing tests exercise the genuine query; the DB-error-surfacing test
# overrides it with Mox.expect/3 to inject a deterministic Postgrex.Error.
config :loopctl, :knowledge_suggest_links, Loopctl.MockSuggestLinks

# Novelty-gated write-back: swap the proposal assessor for a mock so propose_article
# tests choose the verdict deterministically. DataCase default-stubs it to `:novel`
# (gate is a no-op); ProposalGate's own tests call it directly with MockEmbeddingClient.
config :loopctl, :proposal_assessor, Loopctl.MockProposalAssessor
# Merge synthesizer (#4 step 2) — mock so the conflict executor's :merge path is
# deterministic and makes no Anthropic calls.
config :loopctl, :merge_synthesizer, Loopctl.MockMergeSynthesizer

# DI (US-27.3): the router wrapped by LoopctlWeb.Plugs.DBErrorBackstop. A thin
# REAL plug (Loopctl.Test.BackstopRouter) that delegates to LoopctlWeb.Router for
# every request — so the production router stays on the hot path with no global
# Mox mock — and only raises a DB exception uncaught when a request carries the
# opt-in `x-test-raise-db-error` header, exercising the backstop's
# catch/log/sanitize path end-to-end through the real endpoint.
config :loopctl, :db_error_backstop_router, Loopctl.Test.BackstopRouter

# Witness header enforcement disabled in tests — dedicated tests verify
# the plug directly. Other tests don't send the header on secondary conns.
config :loopctl, :enforce_witness_header, false

# DI: Use Req.Test plug for content ingestion URL fetching in tests
config :loopctl, :ingestion_req_plug, {Req.Test, Loopctl.Workers.ContentIngestionWorker}

# Epic 28 (#179): route the tenant-scoped Anthropic client (Loopctl.Llm.Anthropic)
# through a Req.Test plug so the real Claude extractor/classifier/merge modules —
# including per-tenant key resolution and usage recording — are exercised without
# real API calls. DataCase default-stubs it to an empty-articles response; the
# dedicated LLM tests override with crafted content + usage blocks.
config :loopctl, :anthropic_req_plug, {Req.Test, Loopctl.Llm.Anthropic}

# US-41.3: the same seam for the OpenAI-compatible chat client + its config-time
# endpoint probe, so the whole pluggable-provider flow (per-tenant endpoint/key
# resolution, admission, egress chokepoint, shape validation, usage recording) is
# exercised without a real local server.
config :loopctl, :openai_chat_req_plug, {Req.Test, Loopctl.Llm.OpenAiChat}

# Epic 28 (#179) embeddings BYO: route the real tenant-scoped EmbeddingClient
# through a Req.Test plug so its own dedicated test exercises per-tenant key
# resolution + usage recording without real OpenAI calls. Everywhere ELSE the
# embedding client is swapped for Loopctl.MockEmbeddingClient (see above), so this
# plug only matters when a test drives Loopctl.Knowledge.EmbeddingClient directly.
config :loopctl, :embedding_req_plug, {Req.Test, Loopctl.Knowledge.EmbeddingClient}

# DI: Use Req.Test plug for webhook delivery in tests
config :loopctl, :webhook_req_plug, {Req.Test, Loopctl.Webhooks.ReqDelivery}

# US-27.15: webhook delivery DI → a Mox mock in tests. ScaleAlerts and the webhook
# worker both resolve `:webhook_delivery`. The DataCase default stub delegates
# `MockDelivery.deliver/3` to `Loopctl.Webhooks.ReqDelivery` (which honors the Req.Test
# plug above), so the existing webhook-worker tests keep passing; the ScaleAlerts tests
# override `deliver/3` with Mox.expect to assert the firing POST.
config :loopctl, :webhook_delivery, Loopctl.MockDelivery

# US-27.15: a deterministic webhook URL so the ScaleAlerts firing path is EXERCISED in
# tests (a nil URL would short-circuit to log-only). Not a real endpoint — delivery is
# intercepted by the MockDelivery mock.
config :loopctl, :scale_alert_webhook_url, "https://alerts.test.invalid/scale"

# US-27.15: a short window so per-minute rate math in tests is easy to reason about (a
# 60s window = counts are already per-minute). scale_alerts_enabled stays false (config
# default) so the suite never auto-starts ScaleAlerts; tests start it directly.
config :loopctl, :scale_alert_check_interval_ms, 60_000
config :loopctl, :scale_alert_window_ms, 60_000

# DI: Use Req.Test plug for CLI HTTP client in tests
config :loopctl, :cli_req_plug, {Req.Test, Loopctl.CLI.Client}

# Knowledge analytics: record access events synchronously in tests so the
# inserts run inside the test process and share its sandbox connection.
config :loopctl, :analytics_recording_mode, :sync

# #411 Gap 3: bump memory recall_count synchronously in tests so the UPDATE runs
# inside the test process and shares its sandbox connection (a spawned task would not).
config :loopctl, :memory_recall_bump_mode, :sync

# RLS: Switch to non-superuser role within transactions so RLS is enforced
# The loopctl_app role must exist and have access to all tables.
config :loopctl, :rls_role, "loopctl_app"

# KnowledgeMocWorker: low tag threshold so tests need only a few tagged articles.
config :loopctl, knowledge_moc_min_tag_count: 2

# SSRF egress guard DNS resolution DI (ie-02 / worker-01). The UrlGuard resolves
# bare hostnames through this; in tests we swap in a Mox mock so no real network
# DNS is hit. IP-literal test cases (169.254.169.254, ::1, fdaa::1, 2130706433, …)
# bypass DNS entirely via :inet.parse_address. DataCase default-stubs `resolve/1`
# to a public IP so existing example.com-based webhook/ingestion tests keep passing;
# the DNS-rebinding tests override it with Mox.expect/3 to return a private address.
config :loopctl, :dns_resolver, Loopctl.MockDnsResolver

# Bounded DNS resolution (FIX B): the guard resolves under this timeout and fails
# closed if it elapses. Tests use the Mox resolver so this only affects the
# Loopctl.Net.DnsResolver.Default unit test; keep it short so any accidental real
# lookup can't hang the suite.
config :loopctl, :dns_resolve_timeout_ms, 2_000

# Batch ingestion per-item validation deadline (FIX 2). Shorter than the 5s
# production default so the validation_timeout path (a resolver stubbed to
# `Process.sleep(:infinity)`) is exercised without a 5s wait — the hung item does
# UNBOUNDED work, so it deterministically hits ANY finite deadline. But it must
# NOT sit inside the range of normal load jitter for the HAPPY path: a batch's
# items run 10-way concurrent through `async_stream_nolink`, each doing real
# inline-Oban work (serialized on this test's single sandboxed DB connection), so
# the aggregate can spike past a tight deadline under full-suite load and flip an
# innocent "queued" item to a spurious validation_timeout. 200ms was inside that
# jitter band (reproducibly all-timeout at 1ms; observed flaking at 200ms under
# load). 2s gives the bounded fast path ~10x headroom over the observed failure
# point while keeping the (sleep-:infinity) timeout tests fast. Config-based DI —
# no put_env.
config :loopctl, :batch_item_validation_timeout_ms, 2_000

# DI: swap ArticleLinkingWorker's similarity lookup for a Mox mock so the worker's
# linking logic (relates_to / potential_conflict thresholds, dedup, audit, idempotency)
# is unit-tested with deterministic candidate lists — never through the real pgvector kNN,
# which runs under a 250ms SET LOCAL statement_timeout heavy read that flaked those tests
# on a loaded DB (57014 query_canceled). The DataCase default stub returns [] so unrelated
# tests (and the inline-Oban cascade) see no candidates; tests that assert linking set
# Mox expectations. The real VectorSearch.nearest path keeps a dedicated integration test.
config :loopctl, :article_similarity_search, Loopctl.MockArticleSimilaritySearch

# US-36.4: a small corpus-count sample rate so the sampling assertions can pick a
# deterministically sampled/unsampled article by id hash, and a tiny insert chunk size so
# a handful of links exercises the multi-chunk insert_all path without thousands of rows.
config :loopctl, :article_link_corpus_sample_rate, 5
config :loopctl, :article_link_insert_chunk_size, 2

# US-41.4 — the OPERATOR deployment allowlist source. In test it is
# PROCESS-LOCAL (`Loopctl.Test.AllowlistSource`) so an `async: true` test can
# exercise an operator carve-out without `Application.put_env` (forbidden, and a
# global race under async). The allowlist itself stays read-only at every role.
config :loopctl, :local_allowlist_source, Loopctl.Test.AllowlistSource
config :loopctl, :local_endpoint_allowlist, []

# US-41.4 (AC-41.4.6): DISABLE the blocked-decision buffer's periodic flush in
# test. The flush runs in the BlockedBuffer process, which owns no Ecto sandbox
# connection, so a periodic drain would take an `async: true` test's buffered
# counters and then fail to insert them (the tenant lives in another test's
# sandbox transaction). Tests drain their OWN tenant with
# `Loopctl.Egress.flush_blocked_decisions/1`.
config :loopctl, :egress_blocked_flush_ms, :infinity

# US-41.7 (AC-41.7.6 / TC-41.7.8): coverage is a DI seam so both configurations
# (webhook coverage enabled / disabled) are exercisable without `put_env` in a
# test file. The DataCase default stub delegates to the real
# `Loopctl.Custody.Coverage`, so every other test sees production coverage.
config :loopctl, :custody_coverage_source, Loopctl.MockCustodyCoverage

# No debounce in test: a drain immediately after a write must flush the batch.
config :loopctl, :custody_flush_debounce_seconds, 0
