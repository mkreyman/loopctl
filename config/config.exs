# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :loopctl,
  ecto_repos: [Loopctl.Repo],
  # Compile-time env marker (per-env), so runtime code (e.g. the US-27.11 boot-time
  # connection-budget check) can gate prod-only behavior without Mix at runtime.
  env: config_env(),
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  embedding_dimensions: 1536,
  # US-41.1 AC-41.1.3: the FIXED set of embedding dimensions this instance supports.
  # Every value here MUST have pre-created per-dimension HNSW indexes on both
  # `article_embeddings` and `memory_embeddings` (migration
  # `CreatePerDimensionEmbeddingHnswIndexes`), and the same set is published on
  # `.well-known/loopctl` as `supported_embedding_dimensions`. Read at COMPILE TIME by
  # `Loopctl.Knowledge.VectorSearch` (a per-dimension `::vector(N)` cast cannot be a
  # bound parameter), so adding a dimension is a deploy-time change: edit this list AND
  # ship the migration that builds its indexes CONCURRENTLY. Index DDL is
  # operator/migration plane only — never issued from the request path.
  # 768 = nomic-embed / bge-base, 1024 = bge-m3 / mxbai, 1536 = OpenAI 3-small (the
  # hosted default).
  #
  # HARD pgvector CEILING: an hnsw index cannot be built on more than 2000
  # dimensions ("column cannot have more than 2000 dimensions for hnsw index",
  # verified against pgvector 0.8.2). OpenAI text-embedding-3-large's native 3072 is
  # therefore NOT supportable as an indexed dimension on this instance — it would
  # sequential-scan the whole corpus on every query. It is deliberately absent from
  # this list, and `.well-known/loopctl` publishes that fact so an agent discovers
  # the constraint BEFORE configuring a model it cannot use. (3-large can be used at
  # a REDUCED output dimension via the API's `dimensions` parameter; picking 1024 or
  # 1536 there brings it back inside this set.)
  supported_embedding_dimensions: [768, 1024, 1536],
  # US-41.1 (review): TTL (ms) for the memoized semantic-search DISCLOSURE meta
  # (`Loopctl.Embeddings.DisclosureCache`). The system-corpus anti-join + the two
  # re-embed existence probes ran on EVERY semantic response and, in the steady
  # state, always answered the same thing; the answer changes only when the
  # materialization worker runs, a system article is published, or a re-embed makes
  # progress. `0` disables caching entirely (config/test.exs sets 0 so tests observe
  # a disclosure change immediately).
  embedding_disclosure_cache_ms: 5_000,
  # GH #551: the US-41.1 legacy-column RETIREMENT trigger
  # (`Loopctl.Embeddings.LegacyRetirement`). Nothing here drops a column — these two
  # values decide only when the system starts SAYING the drop is owed.
  #
  # - required_clear_days: consecutive UTC days that must show `embedding_side_table_reads
  #   = 1` and zero movement in any legacy index's `idx_scan` before the evidence trigger
  #   fires. 30 is chosen to span the slowest recurring workload that could still touch
  #   the legacy path (the weekly MOC fan-out, the monthly-ish scale runs), so a clear
  #   window means clear, not merely "nothing ran".
  # - review_by: the date past which retirement is owed REGARDLESS of the evidence. Set
  #   six months after the 2026-07-22 read-flag flip. This is the part that makes the
  #   check fail closed: a probe that errors forever, or an `idx_scan` that never settles,
  #   is indistinguishable from "not due yet", so an evidence-only trigger decays
  #   silently back into the prose it replaced. Moving this date out is a legitimate
  #   operator decision — making it moot by accident is not.
  embedding_legacy_retirement: [
    required_clear_days: 30,
    review_by: ~D[2027-01-22]
  ],
  # US-38.4: EXPLICIT pgvector HNSW build parameters for every `CREATE INDEX ... USING
  # hnsw` (`Loopctl.Repo.HnswIndex`). These EQUAL pgvector's implicit defaults (m=16,
  # ef_construction=64) — a deliberate, documented "keep the defaults" tuning outcome
  # (docs/hnsw-tuning-evaluation.md) — but making them config-driven means the choice is
  # intentional and single-sourced. m = graph connectivity (recall/size/build-cost up
  # with m); ef_construction = build-time candidate breadth (recall/build-cost up with
  # it). BUILD-time only: changing either requires an ONLINE reindex migration (CREATE
  # INDEX CONCURRENTLY new, drop old), never an in-place ALTER. The per-QUERY recall knob
  # is `hnsw.ef_search` (SystemConfig `hnsw_ef_search`, applied per-read by HeavyRead).
  hnsw_m: 16,
  hnsw_ef_construction: 64,
  # Cosine similarity threshold for auto-linking articles.
  # 0.6 is calibrated for relationship discovery (related topics).
  # 0.8+ is only useful for near-duplicate detection.
  article_link_threshold: 0.6,
  article_link_max_comparisons: 50,
  # #611 stage 0: a threshold is NOT a bound. Above 0.6 the linking worker took every kNN
  # candidate, so an article contributed up to `article_link_max_comparisons` (50) outbound
  # edges and accrued one inbound edge per article that reached it. The hosted corpus hit
  # 1,402,699 `relates_to` edges over 79,276 articles, 56% of them carrying 21+, at which
  # density any node reaches most of the corpus in two hops and the graph distinguishes
  # nothing. Keep this WELL under max_comparisons — a cap at or above the candidate count
  # is not a cap.
  article_max_relates_to_links: 10,
  # US-27.8 (AC-27.8.4/.6): ADVISORY end-to-end wall-clock budget (ms) for the vector
  # scale gate's timed HTTP requests (suggested_links / semantic search) at the prod
  # floor. SECONDARY to the deterministic plan assertion (index-backed, no full-corpus
  # Sort), which is the real gate; this generous budget catches a serialize/round-trip
  # blow-up without flaking on shared CI hardware. 2000 = the Theme-2 "<2s" target. Tune
  # UP as prod grows beyond the current ScaleSeed floor (a documented step, like bumping
  # @prod_article_floor) — never silently.
  scale_latency_budget_ms: 2_000,
  # US-27.4: log any query slower than this (ms) via the SlowQueryLogger telemetry
  # handler. Tunable in config/env without a code change.
  slow_query_threshold_ms: 1_000,
  # US-27.4: optional per-endpoint SERVER-SIDE statement_timeout overrides (ms) for
  # heavy reads, e.g. %{suggested_links: 5_000}. Endpoints absent here use the default
  # per-read SET LOCAL statement_timeout (HEAVY_READ_STATEMENT_TIMEOUT_MS, default 10s;
  # US-27.13 — NOT a startup :parameters value, which pgbouncer rejects). Keys:
  # :suggested_links, :semantic_search, :distant_pairs, :distant_pairs_bridge, :novelty,
  # :enumeration, :change_feed, :vector_search. NOTE: :semantic_search and :enumeration each
  # issue TWO reads (count + data); setting an override for either wraps EACH read in its own
  # separate transaction, doubling the brief checkout count on the heavy pool. (:distant_pairs
  # USED to be in that list — post-#202/#203 it issues a SINGLE paginated read, its exact-count
  # companion query removed.) :change_feed (US-27.9b) is the rate-limited orchestrator polling
  # feed — a SINGLE cheap keyset read per request; its QPS is bounded by the api pipeline's
  # rate limiter, so it adds at most a brief, fast-releasing checkout and does not erode the
  # K≈6 one-shot fast-read budget.
  #
  # :distant_pairs / :distant_pairs_bridge (#202/#203, HIGH-4) carry a 4s backstop — tighter
  # than the 10s pool default — so a real-scale miss of the Theme-2 <2s target (a deep offset
  # or a rarely-bridged band that defeats the page's early termination) is CANCELED and frees
  # its heavy-read slot fast instead of holding it for 10s. The bridge branch reads under its
  # own key so its (slower) reads are separately observable in slow-query logs.
  heavy_read_statement_timeout_overrides: %{distant_pairs: 4_000, distant_pairs_bridge: 4_000},
  # US-27.12: set-based bulk archive/unpublish/delete. Each op runs in one
  # transaction that first issues `SET LOCAL statement_timeout = <ms>` so a single
  # large statement can't hold an admin-pool connection indefinitely (blast-radius
  # bound, AC-27.12.5). The frozen-set delete token (TOCTOU-safe dry-run, AC-27.12.9)
  # is minted only when the previewed id-set is within `bulk_delete_frozen_max`;
  # over that bound the caller uses re-confirm-on-drift. Tokens expire after
  # `bulk_delete_token_ttl_seconds`.
  bulk_op_statement_timeout_ms: 10_000,
  # US-27.16: streaming knowledge export (bounded-memory `.tar.gz`).
  # - export_chunk_size: articles read per keyset page (peak in-memory articles).
  # - export_max_links_per_article: per-article neighbor cap so a dense hub's link
  #   fan-out can't materialize an unbounded entry (applied in SQL).
  # - export_max_concurrent_global / _per_tenant: hard caps on in-flight streaming
  #   exports; over the cap → 429 (off the admin pool). The global default (2)
  #   matches the heavy-read pool's export reservation (see runtime.exs).
  # - export_max_stream_duration_ms: documented TIME budget per export (not a count
  #   cap); exceeding it aborts the stream fail-closed.
  # - import_export_max_compressed_bytes / _decompressed_bytes: decompression-bomb
  #   defense for archive imports (#3). The compressed cap rejects an over-large
  #   input before any inflation; the decompressed cap aborts a streaming inflate
  #   mid-bomb. Defaults 50 MB / 200 MB; tunable for very large knowledge bases.
  export_chunk_size: 200,
  export_max_links_per_article: 100,
  # US-27.16: the streaming-export producer's per-body observation seam. Production
  # observes nothing (the producer must NOT retain bodies — that is the property the
  # bounded-memory gate protects); config/test.exs swaps in a Mox mock so the scale gate
  # can inject a RETAINING probe and prove that metric is load-bearing.
  streaming_export_body_probe: Loopctl.Knowledge.StreamingExport.NoopBodyProbe,
  export_max_concurrent_global: 2,
  export_max_concurrent_per_tenant: 1,
  export_max_stream_duration_ms: 600_000,
  import_export_max_compressed_bytes: 50 * 1024 * 1024,
  import_export_max_decompressed_bytes: 200 * 1024 * 1024,
  # Transaction-level timeout (ms) handed to `AdminRepo.transaction/2` — set a bit
  # above the per-statement timeout so the connection is RECLAIMED even if several
  # statements chain (links_src + links_tgt + articles + audit), instead of holding
  # one of the small admin-pool connections for the sum of their runtimes.
  bulk_op_transaction_timeout_ms: 15_000,
  bulk_delete_frozen_max: 1_000,
  bulk_delete_token_ttl_seconds: 300,
  # US-27.15: scale telemetry metrics + Prometheus reporter (internal :9568/metrics,
  # scraped by Fly's managed Prometheus over 6PN).
  # - metrics_reporter_enabled: start the SUPERVISED Prometheus reporter child. OFF by
  #   default (so :test never binds the port); turned ON in prod (runtime.exs). Flip it
  #   on in dev to inspect localhost:9568/metrics.
  # - metrics_port: the internal port the reporter binds for /metrics (NEVER the public
  #   8080 http_service). Matches the fly.toml [metrics] block.
  # - metrics_tenant_label_cap: the documented tenant-count cap (AC-27.15.3). The
  #   `tenant_id` COUNTER label is allowed only while total tenants <= this; above it the
  #   label collapses to the `:_aggregated` sentinel (cardinality 1) and per-tenant
  #   attribution falls back to logs. tenant_id is NEVER a histogram label. The gate is
  #   cached in :persistent_term and refreshed by a telemetry_poller measurement — no
  #   per-emit DB hit.
  metrics_reporter_enabled: false,
  metrics_port: 9568,
  metrics_tenant_label_cap: 1_000,
  # US-27.15 (AC-27.15.2): the FIRING alert path — Loopctl.Telemetry.ScaleAlerts. Fly's
  # managed Grafana has alerting DISABLED, so the PromQL rules only VISUALIZE; this
  # loopctl-owned threshold checker is what actually fires. It windows the three scale
  # signals (via atomic ETS counters, no per-event GenServer call), and on a threshold
  # breach POSTs a small id-only alert to an operator webhook via the SAME
  # `:webhook_delivery` DI the webhook worker uses (no tenant content / vectors / SQL).
  # - scale_alerts_enabled: start the SUPERVISED ScaleAlerts child. OFF by default (so
  #   :test never runs its timers / owns its ETS table). runtime.exs defaults it ON in
  #   prod, but it is an env toggle (SCALE_ALERTS_ENABLED, #376) and the hosted
  #   deployment currently ships it "false" via fly.toml, so the child is NOT started
  #   there today. OFF means the whole checker is absent — nothing evaluated or logged,
  #   not merely nothing POSTed.
  # - scale_alert_webhook_url: the operator webhook (Slack/PagerDuty/generic). nil =
  #   alerting OFF (opt-in) — a breach is logged, nothing is POSTed. Set in runtime.exs
  #   from SCALE_ALERT_WEBHOOK_URL. The two settings must AGREE: either combination of
  #   one-without-the-other is flagged by ScaleAlerts.config_status/2.
  # - scale_alert_check_interval_ms: how often the tumbling window is evaluated + reset.
  # - scale_alert_window_ms: the window length (defaults to the check interval) — used to
  #   turn counts into per-minute rates and to report window_seconds in the payload.
  # - the three thresholds (documented defaults): timeouts/min, p95 heavy-read ms,
  #   under-fill events/min. Edge-triggered debounce: an alert fires on the transition
  #   INTO breach, re-arming once the metric clears (no per-interval spam).
  # - scale_alert_renotify_interval_ms (US-34.5, AC-34.5.2): while a breach remains
  #   sustained, re-fire once this interval has elapsed since the last notification
  #   instead of firing exactly once — an hours-long breach keeps paging. Floored at
  #   60_000ms in `ScaleAlerts.renotify_interval_ms/0` so misconfiguration can't turn
  #   this into per-tick spam. Delivery (US-34.5, AC-34.5.1) is durable: alerts are
  #   enqueued through `Loopctl.Workers.ScaleAlertDeliveryWorker` (Oban `:webhooks`
  #   queue) rather than POSTed synchronously, so a transient failure retries with
  #   Oban's backoff instead of being logged-and-dropped.
  scale_alerts_enabled: false,
  scale_alert_webhook_url: nil,
  scale_alert_check_interval_ms: 60_000,
  scale_alert_timeout_rate_per_min: 5,
  scale_alert_p95_latency_ms: 2_000,
  scale_alert_under_fill_rate_per_min: 30,
  scale_alert_renotify_interval_ms: 15 * 60_000,
  # US-34.3: three additional signals (documented defaults) — Repo checkout
  # queue_time p95 (ms), fleet-wide Oban discard/retry rate (events/min), and
  # LLM/embedding provider-error rate (events/min).
  scale_alert_queue_time_p95_ms: 500,
  scale_alert_oban_discard_rate_per_min: 10,
  scale_alert_provider_error_rate_per_min: 10

# Ingestion capture-silence monitor (dead-man's-switch for knowledge capture).
# Config-based DI for `Loopctl.Knowledge.IngestionHealth` — all tunables have
# in-code defaults in that module, so this block is an override point, not a boot
# dependency. `:monitored_source_types` are the article `source_type`s watched for
# silence; `:all` (the default) monitors EVERY source_type that crosses the
# established threshold — a silent-capture outage affects any source_type
# (knowledge_create 409 drops hit web_article/newsletter/session_log alike), so the
# monitor defaults to broad coverage rather than session_log-only. A list narrows it.
# `:established_threshold` is the minimum article count (within the establishment
# window) before a source_type is considered "established" (and thus eligible to be
# flagged when it goes silent); `:staleness_threshold_hours` is how long an
# established source_type may go without a new article before `IngestionHealthWorker`
# flags a `:capture_silence` anomaly; `:establishment_window_hours` scopes
# establishment to RECENT activity so a wound-down source_type is not flagged forever.
#
# PR B2 (no-persist / high-rejection-rate detector): `:reject_rate_threshold` is the
# fraction of window write attempts above which a source_type is flagged
# `:high_reject_rate` (rejects / total_attempts > threshold); `:min_attempts` is the
# minimum window write attempts before that ratio is trusted (noise floor);
# `:reject_window_days` is the rolling window (days) over the `ingestion_write_stats`
# rollup the reject-rate scan reads.
config :loopctl, :ingestion_health,
  # capture_silence is RETIRED (owner decision, 2026-08-09): an empty list monitors no
  # source_type, so `IngestionHealth.detect/0` yields no candidates and the worker flags
  # nothing. It scopes that detector ONLY — `:high_reject_rate` and `:sweep_stalled` are
  # separate detectors with their own config and are unaffected.
  #
  # Why retire rather than tune: the signal cannot tell a ONE-OFF HARVEST that finished
  # from a standing feed that broke, and this corpus is built by harvests. Every anomaly
  # it ever raised (web_article, interview, requirements, repo, newsletter — 5 rows,
  # 23-31 days stale) was a completed import, so the detector was 100% false-positive
  # here while `session_log`, the only continuous producer, never tripped it.
  #
  # To re-enable for a source that IS a standing feed, name it explicitly rather than
  # going back to `:all` — e.g. `["session_log"]`. That is the shape this detector is
  # actually good at.
  monitored_source_types: [],
  established_threshold: 5,
  staleness_threshold_hours: 72,
  establishment_window_hours: 720,
  reject_rate_threshold: 0.5,
  min_attempts: 10,
  reject_window_days: 7,
  # Retention (days) for the append-only `ingestion_write_stats` rollup; the hourly
  # worker prunes older rows so the table (and the cross-tenant reject-rate scan) stays
  # bounded. Only the rolling `reject_window_days` window is ever read.
  write_stats_retention_days: 90,
  # #498 (retention-sweep stall detector): grace hours past `expires_at` after which a
  # still-present `channel_posts` row means the US-39.5 sweep is not being enforced for
  # that tenant. The sweep runs every 5 minutes, so 6h is ~72 consecutive missed runs.
  sweep_staleness_hours: 6,
  # Staleness ceiling past which residue is flagged REGARDLESS of drain capacity — the
  # backstop for a backlog the bounded sweep can never drain (and the worst-case alarm
  # latency for a dead sweep hiding behind a backlog larger than sweep_scan_limit).
  sweep_hard_stale_hours: 24,
  # Install-wide rows/hour the bounded sweep can delete (1000-row batch x 12 runs/hour).
  # Below the hard ceiling, a TENANT's own residue this large is BACKLOG, not a stall —
  # flagging it would page an operator about a healthy sweep that is simply still
  # draining.
  sweep_drain_rate_per_hour: 12_000,
  # Hard cap on residue rows scanned per detection: the residue only grows while the
  # sweep is behind, so an unbounded count would be most expensive exactly when the
  # system is least healthy — on the 3-connection AdminRepo pool.
  #
  # INVARIANT (asserted by test): this MUST stay above
  # sweep_drain_rate_per_hour x sweep_staleness_hours (12_000 x 6 = 72_000). At the
  # previous 50_000 a residue could never be OBSERVED as large as the capacity threshold
  # it is compared against, so the "residue >= capacity => merely BACKLOGGED" rule was
  # arithmetically unreachable and sweep_drain_rate_per_hour was an inert knob. The
  # larger cap is free in a healthy install: it only ever scans rows already past
  # expires_at + grace, of which a running sweep leaves none.
  sweep_scan_limit: 100_000

# US-33.3: bounded TTL (ms) for the ETS read-through api-key cache. This is the
# defense-in-depth backstop, NOT the primary invalidation — every revoke/rotate/
# mutate writer busts the key_hash entry in-band. A cached entry is re-validated
# against the DB after at most this long even absent an explicit invalidation, so
# any missed path self-heals within the TTL (AC-33.3.4). Default 60s (within the
# 30-60s range the AC specifies); overridable per-env.
config :loopctl, Loopctl.Auth.ApiKeyCache, ttl_ms: :timer.seconds(60)

# US-33.4: flush interval (ms) for the debounced liveness touch buffer
# (agents.last_seen_at / api_keys.last_used_at). Per-request touch-writes are
# collapsed into one batched, monotonic UPDATE per active id every interval, so
# these liveness heuristics are at most one interval stale (AC-33.4.4). Default a
# few seconds; overridable per-env.
config :loopctl, Loopctl.TouchBuffer, flush_interval_ms: :timer.seconds(5)

# AdminRepo shares the same database but uses a role with BYPASSRLS in production.
# In dev/test, it uses the same credentials as Repo.
config :loopctl, Loopctl.AdminRepo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  types: Loopctl.PostgrexTypes

# HeavyReadRepo (US-27.11) — a dedicated pool for heavy BYPASSRLS vector/enumeration
# reads, isolated from the small AdminRepo pool and carrying a pool-level
# statement_timeout (set in runtime.exs). Same database as Repo/AdminRepo; never in
# `ecto_repos` (it owns no migrations). See Loopctl.HeavyReadRepo / Loopctl.HeavyRead.
config :loopctl, Loopctl.HeavyReadRepo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  types: Loopctl.PostgrexTypes

# Ecto migration defaults — binary UUIDs for all primary and foreign keys
config :loopctl, Loopctl.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  types: Loopctl.PostgrexTypes

# Configure the endpoint
config :loopctl, LoopctlWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LoopctlWeb.ErrorHTML, json: LoopctlWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Loopctl.PubSub,
  live_view: [signing_salt: "xpgWTdmT"]

# RemoteIp `:proxies` — trusted intermediary CIDRs, honored by the shared
# `Loopctl.RemoteIp` resolver (used by BOTH `LoopctlWeb.Plugs.ClientIp` and
# `LoopctlWeb.SignupLive`). `Loopctl.RemoteIp` resolves `fly-client-ip` and
# `x-forwarded-for` INDEPENDENTLY (each with a SINGLETON `:headers` list), so we
# deliberately do NOT set a multi-header `:headers` here: that would trigger
# RemoteIp's wire-order collapse where Fly's app IP (appended as the rightmost
# X-Forwarded-For entry) wins the right-to-left scan and buckets everyone
# together. `fly-client-ip` (set by fly-proxy to the real client, unforgeable)
# is preferred; `x-forwarded-for` is the off-Fly fallback.
#
# `:proxies` = Fly's `fdaa::/16` 6PN by default; add another reverse proxy's
# egress CIDR if one fronts this app.
#
# RESIDUAL (documented, accepted infra boundary): a malicious SAME-Fly-org
# sibling app with direct 6PN access to this app's port could set `fly-client-ip`
# itself. Same-org is a trusted boundary — a hostile sibling app is a far larger
# compromise than signup rate limits — so this is NOT a reachable vuln for the
# normal public-internet threat model.
config :loopctl, :remote_ip_opts, proxies: ~w[fdaa::/16]

# Configure Elixir's Logger — structured JSON logging with tenant context.
# Production uses JSON via LoggerJSON; dev/test override with human-readable format.
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: [
       :request_id,
       :tenant_id,
       :remote_ip,
       # US-27.3: structured DB-error fields so a mapped DB error is emitted as
       # first-class JSON fields in prod (AC-27.3.3), not just inline in the
       # message. sqlstate/mapped_code make a 57014 timeout self-identifying.
       :sqlstate,
       :mapped_code,
       :controller,
       :action,
       :pg_message,
       # US-27.4: slow-query log fields (duration_ms, repo, source, endpoint).
       :duration_ms,
       :repo,
       :source,
       :endpoint
     ]}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.0",
  loopctl: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.0.14",
  loopctl: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Redact secrets from Phoenix's request-parameter debug log (Epic 28, #179 review):
# PATCH /api/v1/tenants/me/llm-config carries a raw `api_key` in its body. This
# applies in ALL envs so the plaintext key can never surface in the Phoenix
# "Parameters:" log line even if debug logging is enabled.
#
# NOTE (scope): this closes the PHOENIX PARAM-LOG path. Ecto's own :debug SQL-query
# log still prints the plaintext value of ANY Cloak `Loopctl.Vault.Binary` field
# (the existing webhook signing secret leaks identically — a pre-existing,
# codebase-wide Ecto+Cloak logging behaviour, NOT specific to this feature). Prod
# runs at :info, so :debug SQL logs never emit there; redacting encrypted-field
# params from Ecto's logger is a separate cross-cutting change.
config :phoenix,
       :filter_parameters,
       {:discard, ["password", "api_key", "secret", "token", "authorization"]}

# Override phoenix_ecto's Plug.Exception impls:
# - CastError (default: 400 -> our: 404): an invalid UUID in a URL path means
#   the resource cannot exist, hence 404 (see LoopctlWeb.Plugs.CastErrorHandler).
# - Postgrex.Error (default: blanket 500): US-27.3 maps known SQLSTATE classes
#   to pinned 504/503/500 instead (see LoopctlWeb.Plugs.DBErrorHandler). Excluded
#   here so our single impl is authoritative and phoenix_ecto doesn't redefine it.
config :phoenix_ecto, :exclude_ecto_exceptions_from_plug, [
  Ecto.CastError,
  Ecto.Query.CastError,
  Postgrex.Error
]

# Hammer rate limiting (ETS backend)
#
# sec-4: `pool_size`/`pool_max_overflow` size the poolboy worker pool that fronts
# EVERY `check_rate/3` call (Hammer.Supervisor defaults are 4 / 0). The
# fail-CLOSED `LoopctlWeb.Plugs.AuthPathThrottle` runs first in the :authenticated
# pipeline and calls the limiter on every request — including the ones it is about
# to 429 — so a single-IP flood keeps hitting this pool at full rate while denied.
# On the default 4-worker pool a poolboy checkout can then time out and exit,
# which the fail-CLOSED gate normalises to a denial, spilling 429s onto LEGITIMATE
# traffic from OTHER IPs (a cross-tenant collateral denial under the very flood the
# gate defends against). A generous pool of fast (microsecond) ETS checks removes
# that saturation headroom. Operator-overridable at runtime (config/runtime.exs).
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       expiry_ms: 60_000 * 60,
       cleanup_interval_ms: 60_000 * 10,
       pool_size: 20,
       pool_max_overflow: 10
     ]}

# Oban background jobs
config :loopctl, Oban,
  repo: Loopctl.Repo,
  # NB: hand-maintained mirror of Loopctl.ObanConfig.@default_queues — keep in sync
  # (oban_config_test.exs TC-32.2.1 + oban_queue_topology_test.exs AC-36.1.5 assert it).
  # US-36.1: `:knowledge` 5 -> 3 + `:default` 10 -> 9 fund `:ingestion` 2 + `:verification`
  # 1 (rebalance, pool sum stays 38). See ObanConfig's @default_queues comment for the
  # fast-lane (knowledge=3) rationale.
  queues: [
    default: 9,
    webhooks: 5,
    cleanup: 2,
    analytics: 3,
    maintenance: 2,
    embeddings: 5,
    knowledge: 3,
    ingestion: 2,
    memory: 3,
    audit: 3,
    verification: 1
  ]

# US-41.7 (AC-41.7.6) — which egress paths a custody claim ATTESTS to. Driven by
# configuration rather than hardcoded so the claim's scope is an explicit,
# reviewable fact. `Loopctl.Custody.Coverage` INTERSECTS this with the paths for
# which a per-row posture entry is actually recorded, so adding a path here can
# never make the surface over-claim.
config :loopctl, :custody_coverage, covered_paths: [:provider_calls]

# Seconds the per-tenant custody posture chain-append batch is debounced by. The
# debounce IS the AdminRepo pool budget (3 connections): a bulk harvest collapses
# to one append per window instead of one per article.
config :loopctl, :custody_flush_debounce_seconds, 5

# US-37.2 (GH #352): per-node ceiling on concurrent OUTBOUND embedding calls
# (`Loopctl.Knowledge.EmbeddingConcurrency`). This is the in-code default used on a
# `SystemConfig` cache miss; operators retune it live (no deploy) via the
# `"embedding_max_concurrent"` SystemConfig key. Because BOTH the interactive query
# path and the two Oban embedding workers acquire the SAME slot, this is the TOTAL
# node ceiling — sized to ~2x the background `embeddings` queue (5) so a normal
# search never waits on a slot while a runaway interactive burst is still shed well
# below the provider's hard ceiling. Node-local (distributed coordination is Epic 38).
config :loopctl, :embedding_max_concurrent, 10

# US-37.2 per-tenant sub-cap: the MOST outbound embeds a SINGLE tenant may hold of
# the global budget at once, so one tenant's interactive burst can't silently starve
# every other tenant's semantic search (mirrors `ExportConcurrency`'s per-tenant cap
# and the per-tenant embedding circuit breaker — a bursting tenant degrades ITSELF).
# In-code default on a `SystemConfig` cache miss; operators retune live (no deploy)
# via the `"embedding_max_concurrent_per_tenant"` SystemConfig key. `6` of the global
# `10` keeps a single active tenant unthrottled on an idle node while always leaving
# slots for neighbours. Node-local (distributed coordination is Epic 38).
config :loopctl, :embedding_max_concurrent_per_tenant, 6

# US-35.3: the Oban `:plugins` list (Cron crontab + Lifeline + Pruner + Reindexer)
# moved to `Loopctl.ObanConfig.plugins/0` and is set at RUNTIME in `config/runtime.exs`
# (`config :loopctl, Oban, plugins: Loopctl.ObanConfig.plugins()`). It lives there —
# not here — so the all-tenants ComputeSthWorker safety-sweep schedule is driven by
# `STH_SWEEP_CRON` (`Loopctl.ObanConfig.sth_sweep_cron/0`, default `*/5 * * * *`) and is
# tunable/revertible per environment without a deploy. NB: unlike `queues:` (a keyword
# list that `Config` deep-merges), `:plugins` is a plain list that `Config` REPLACES
# wholesale, so it must be owned entirely by whichever layer sets it last (runtime.exs).
# Do NOT re-add a compile-time `plugins:` here — it would be overwritten at boot.

# US-34.1 (AC-34.1.4): Stager is NOT a `plugins:` entry in this Oban version
# (2.21) — it was absorbed into Oban's core engine and is now configured via the
# top-level `:stage_interval` key (default 1s, unset here so Oban's own default
# applies). Documenting this explicitly rather than silently relying on it: an
# older Oban release configured `{Oban.Stager, ...}` as a plugin, so a reader
# coming from that era would otherwise wonder why it's missing from the list
# above. No change intended here — the default staging interval is fine.

# US-34.1 (AC-34.1.2/.3): tunables for the two Oban queue/state/orphan telemetry
# pollers (`Loopctl.Telemetry.ScaleMetrics.poll_oban_queue_state/0` and
# `poll_oban_executing_orphans/0`), wired into `LoopctlWeb.Telemetry`'s shared
# `telemetry_poller` (every 10s).
#
# - poll_statement_timeout_ms: the per-query SET LOCAL statement_timeout each poll
#   applies — short and bounded, so a slow poll can never itself saturate the
#   AdminRepo pool.
# - orphan_threshold_minutes: how old an `executing` job's `attempted_at` must be to
#   count as an orphan. Deliberately ABOVE the Lifeline `rescue_after` window (30
#   min, above) so a non-zero reading means Lifeline is genuinely falling behind or
#   a job is wedged past Lifeline's own rescue point.
config :loopctl, :oban_metrics_poll_statement_timeout_ms, 2_000
config :loopctl, :oban_metrics_orphan_threshold_minutes, 45

# US-36.4: ArticleLinkingWorker hot-path efficiency tunables. This is the highest-frequency
# :knowledge job (one per embedded article), so per-job waste multiplies under bulk ingest.
# - article_link_statement_timeout_ms: per-query SET LOCAL statement_timeout wrapping the
#   batched link insert_all and the sampled corpus-size count, so neither can hold an
#   AdminRepo connection indefinitely. SET LOCAL is pgbouncer-safe (no startup parameter).
# - article_link_corpus_sample_rate: the corpus-size-vs-limit warning was a full count(*)
#   on EVERY job, paid only to feed a warning log. It now runs on ~1/N jobs, chosen
#   deterministically by article-id hash (`:erlang.phash2(article_id, N) == 0`), and emits a
#   [:loopctl, :knowledge, :article_linking, :corpus_size] telemetry event alongside the
#   over-limit warning. N=1 samples every job; N<=0 disables it; a larger N samples less.
# - article_link_insert_chunk_size: rows per insert_all batch, keeping a dense article's
#   link fan-out well under Postgres's 65535 bind-parameter ceiling (~6 params/row).
config :loopctl, :article_link_statement_timeout_ms, 3_000
config :loopctl, :article_link_corpus_sample_rate, 100
config :loopctl, :article_link_insert_chunk_size, 1_000

# US-34.2: the COUNT threshold that trips `Loopctl.HealthCheck.Default`'s
# `oban_orphans` readiness sub-check into "error" — distinct from the AGE
# threshold above (`oban_metrics_orphan_threshold_minutes`: WHICH jobs count as
# orphans). This one decides HOW MANY of those orphans must pile up before the
# node reports degraded readiness. Default 10 is safe even though modest: the
# age threshold already restricts the count to jobs stuck in `executing` for
# 45+ minutes, so a normal transient backlog (a few slow jobs mid-retry) never
# reaches double digits and won't flap readiness — but the sustained 17-day/
# 110-orphan stall this story addresses trips it immediately.
config :loopctl, :oban_orphan_health_threshold, 10

# US-35.2: debounce window (seconds) for the event-driven STH enqueuer
# (`Loopctl.AuditChain.SthEnqueuer`). Read at runtime via Application.get_env/3.
# Drives BOTH the enqueued ComputeSthWorker job's `schedule_in` AND its Oban
# `unique` `period`, so a burst of appends for one tenant within this window
# collapses to a single scheduled job (Basic-Engine-safe dedup). Short by design:
# it only delays the activity-driven STH sign by a few seconds while coalescing
# bursts; the low-frequency cron sweep (US-35.3, below) remains the correctness backstop.
config :loopctl, :sth_enqueuer_debounce_seconds, 5

# US-35.3: all-tenants ComputeSthWorker safety-sweep cron. Reduced from `"* * * * *"`
# (every minute) to a low-frequency, config-driven backstop (default `*/5 * * * *`) that
# only catches audit appends the event-driven enqueuer (US-35.2, above) missed. The
# expression is NOT set here — it is read from the `STH_SWEEP_CRON` env var at runtime by
# `Loopctl.ObanConfig.sth_sweep_cron/0` and installed into the Oban crontab via
# `Loopctl.ObanConfig.plugins/0` in `config/runtime.exs`, so an operator can slow or
# revert the sweep with `fly secrets set STH_SWEEP_CRON=... && restart` — no deploy.
# Correctness is interval-independent: every fanned-out per-tenant job still self-gates on
# `Loopctl.AuditChain.sth_needed?/1`, so a slower poll can only delay (never corrupt) an
# STH, and only for a tenant the event path also missed, by up to one sweep interval.

# Cloak Vault — keys configured per environment
# Generate a key: :crypto.strong_rand_bytes(32) |> Base.encode64()
# The actual ciphers are set in config/runtime.exs (from CLOAK_KEY / CLOAK_KEY_TAG /
# CLOAK_RETIRED_KEYS) or config/test.exs. Default is empty — prod raises at startup if
# CLOAK_KEY is not set.
#
# ROTATION (#622, #493): retired keys are an ENV concern, not a compile-time one — set
# CLOAK_RETIRED_KEYS and run `mix loopctl.reencrypt_secrets`. Full procedure and its
# ordering constraints: docs/runbooks/cloak-key-rotation.md.
#
# There is deliberately no `retired_ciphers:` key here. Cloak reads ONLY `:ciphers`
# (`Cloak.Vault.decrypt/2` scans that one list), so the `retired_ciphers:` this used to
# carry was inert — a rotation that followed it would have produced undecryptable rows.
config :loopctl, Loopctl.Vault, ciphers: []

# DI: Content extractor for knowledge ingestion.
# US-41.3: the module named here is the TENANT-AWARE ROUTER — it still is the one
# `Application.get_env` resolution point, and it dispatches per call to the
# Anthropic or OpenAI-compatible sibling based on the tenant's settings. A tenant
# that configures nothing keeps Anthropic, unchanged (AC-41.3.7).
config :loopctl, :content_extractor, Loopctl.Knowledge.ContentExtractorRouter

# DI: Memory promotion compiler LLM (Epic 29). The production impl wraps the
# shared tenant-scoped Anthropic client (operation :extraction) with temperature 0
# and a fixed injection-hardened prompt. Overridden by a Mox mock in test env.
# US-41.3: tenant-aware router (dispatches to DefaultLLM or OpenAiLLM per tenant).
config :loopctl, :promoter_llm, Loopctl.Memory.Promoter.LLMRouter

# Memory promotion tunables (Loopctl.Memory.Promoter.compile/2). Candidates below
# the confidence threshold are dropped; the result is capped to the top-N by
# confidence. Query-shaped defaults; documented in the module.
config :loopctl, :memory_promotion_confidence_threshold, 0.5
config :loopctl, :memory_promotion_max_candidates, 5

# Auto-promotion loop tunables (Epic 29 / US-29.2).
#
# - compiles_per_hour: per-tenant cap on promotion COMPILES (each compile = one LLM
#   call), enforced BEFORE any LLM call in `Loopctl.Memory.promote_session/1` and the
#   sweep, so a spamming agent or a tenant with thousands of stale sessions cannot
#   exhaust its BYO LLM key.
# - near_dup_threshold: cosine score at/above which a candidate supersedes the nearest
#   existing memory instead of inserting a fresh row.
# - sweep_max_per_tick / sweep_scan_limit: bound the cross-tenant sweep's fan-out.
# - session_memory_ttl_seconds: the DEFAULT session-turn lifetime. `Loopctl.Memory`
#   sets a session turn's `expires_at` to `now + this` when the caller omits it, and
#   FLOORS any caller-supplied `expires_at` to `now + sweep_window_seconds` — so both
#   knobs govern the real per-row prune deadline (see `Loopctl.Memory` server-governed
#   expiry). The sweep window MUST be strictly shorter than this TTL so turns are
#   promoted before `SessionMemoryPruneWorker` deletes them; that invariant is asserted
#   at boot in `Loopctl.Application.start/1` (via `assert_promotion_ttl_invariant!/0`).
# - sweep_interval_seconds: the ACTUAL cadence of `MemoryPromotionSweepWorker`. It MUST
#   equal the sweep's crontab entry above (`*/10` = 600s) — it is the data form of that
#   schedule so the boot invariant can model the REAL binding constraint. NB (#249): that
#   crontab entry is currently PARKED (`ObanConfig.parked_crons/0`) because the memory tier
#   holds no rows, so the invariant presently constrains a schedule that is not installed.
#   Keep the two in sync anyway — `OBAN_UNPARK_CRONS` reinstalls the entry with no deploy,
#   and the invariant must already be true at the moment it does. The expiry
#   FLOOR (sweep_window_seconds) MUST be strictly greater than this interval so a turn
#   created at any point survives until a LATER sweep tick (plus promotion-job latency
#   headroom) rather than racing its first eligible tick against the prune worker. Keep
#   this in sync if you change the `*/10` crontab entry.
config :loopctl, :memory_promotion_compiles_per_hour, 200
config :loopctl, :memory_promotion_near_dup_threshold, 0.92
config :loopctl, :memory_promotion_sweep_max_per_tick, 100
config :loopctl, :memory_promotion_sweep_scan_limit, 2000
config :loopctl, :memory_promotion_sweep_interval_seconds, 600
config :loopctl, :memory_promotion_sweep_window_seconds, 900
config :loopctl, :session_memory_ttl_seconds, 3600

# Memory GRADUATION tunables (#411 Gap 3 — Loopctl.Workers.MemoryGraduationSweepWorker).
# A DISTINCT, higher tier than the promotion loop above: a long-term memory recalled at
# least `recall_threshold` times (via a HEALTHY semantic recall — the ILIKE fallback does
# NOT bump the counter, so a provider outage cannot skew the signal) is graduated into a
# durable Knowledge Wiki article, deduped by the novelty gate.
# - recall_threshold: recall-count at/above which a memory is eligible to graduate.
# - max_per_run: per-tick execution budget — the max memories one hourly sweep processes,
#   bounding the novelty-gate embedding spend per run.
# - scan_limit: max distinct TENANTS a sweep tick considers (a tenant cap, NOT a row cap).
#   The sweep needs at most max_per_run tenants and pulls ~ceil(max_per_run / n_tenants)
#   rows each, so worst-case candidate rows fetched per tick is ~2*max_per_run, not
#   scan_limit*max_per_run.
config :loopctl, :memory_graduation_recall_threshold, 3
config :loopctl, :memory_graduation_max_per_run, 50
config :loopctl, :memory_graduation_scan_limit, 500

# Dedup window (seconds) for the recall-count hotness bump (`Loopctl.Memory.bump_recall_counts/2`).
# A memory's `recall_count` is bumped at most once per window, so a single agent replaying the
# same query in a tight loop cannot inflate the "frequently-recalled" signal and force premature
# graduation. Genuine repeated value across sessions/time still accumulates across windows.
config :loopctl, :memory_recall_bump_cooldown_seconds, 3600

# Minimum cosine similarity a recalled memory must clear for its hotness bump to count
# (`Loopctl.Memory.recall_bump_min_score/0`). recall returns the top-k by distance
# regardless of absolute relevance, so without a floor a sparse subject scope (fewer than
# k live memories) would auto-graduate low-relevance NOISE. Only a recall at/above this
# similarity (`max(0.0, 1.0 - distance)`) bumps recall_count.
config :loopctl, :memory_recall_bump_min_score, 0.6

# Max concurrent in-flight recall-count bump tasks per node
# (`Loopctl.Memory.RecallBumpTaskSupervisor` max_children). Bounds the fan-out of the
# fire-and-forget async bump so a recall burst cannot spawn unbounded background writes
# that starve the write pool — over the cap the bump is simply dropped (best-effort).
config :loopctl, :memory_recall_bump_max_tasks, 200

# Epic 30 / US-30.1: per-tenant cap on entity definitions
# (`Loopctl.ContextRetriever.Registry`). Bounds the dynamic ListTools payload/
# latency of the generated agent query surface so a tenant admin cannot inflate
# it without limit. Over-cap creation returns `{:error, :entity_limit}`.
config :loopctl, :max_entity_definitions_per_tenant, 50

# Epic 30 / US-30.3: hard maximum page size for the Context Retriever query
# executor (`Loopctl.ContextRetriever.Executor`). Every generated filter/search
# query is capped at this many rows so a model-driven query can never request an
# unbounded result set; a caller-supplied `limit` is clamped to `[1, this]`.
config :loopctl, :context_retriever_max_page_size, 100

# Epic 30 / US-30.3: hard maximum pagination OFFSET for the Context Retriever
# query executor. A caller-supplied `offset` is clamped to `[0, this]` so a
# model-driven call cannot force an O(offset) deep-scan (Postgres walking and
# discarding an arbitrarily large offset) on the governed query surface. Deep
# paging still works up to this generous bound.
config :loopctl, :context_retriever_max_offset, 100_000

# Epic 30 / US-30.4: per-tenant rate limit on the model-invoked
# `POST /api/v1/retrieve/:entity` endpoint (in ADDITION to the global per-key/
# per-tenant request limiter). Bounds how often a single tenant may fire the
# Context Retriever executor within a rolling window so a looping/hostile agent
# cannot flood it; over-limit returns 429 without executing.
config :loopctl, :context_retriever_retrieve_rate_window_ms, 60_000
config :loopctl, :context_retriever_retrieve_rate_limit, 120

# L3 local test runner (Loopctl.Verification.TestRunner). DISABLED by default:
# it clones a tenant-supplied repo and runs `mix deps.get`/`mix test` on it
# (untrusted-code execution) and is subject to a clone-time DNS-rebinding SSRF
# residual. Enable ONLY inside an egress-restricted, ephemeral sandbox.
config :loopctl, :enable_local_test_runner, false

# US-33.7 — Flag-guarded RLS-Repo reroute pilot (Epic 33, DB Connection Topology).
# DEFAULT OFF. When true, `Loopctl.WorkBreakdown.Stories.list_stories_by_project/3`
# reads through the RLS `Loopctl.Repo` (via `Repo.with_tenant/2`) instead of the
# BYPASSRLS `Loopctl.AdminRepo`. This is a SECURITY-BOUNDARY change: the RLS path
# keeps the explicit `where s.tenant_id == ^tenant_id` predicate (belt-and-suspenders)
# AND relies on RLS enforcement, and fails closed (zero rows) on a missing tenant
# context. Kept OFF in prod unless the prod `Repo` role is verified to lack BYPASSRLS
# (AC-33.7.4). The blanket reroute of all OLTP through the RLS Repo remains OUT OF
# SCOPE (a separate future epic); this pilot is its parity + cost evidence base
# (AC-33.7.6).
#
# This line is the compile-time DEFAULT (dev/test + a safe OFF baseline). In PROD the
# value is driven at RUNTIME by the `RLS_REROUTE_LIST_STORIES_BY_PROJECT` env var in
# config/runtime.exs — so flipping it on, or rolling it back, is an env-var change +
# restart with NO rebuild/redeploy of the release (AC-33.7.5), matching the sibling
# Epic-33 knobs (HEAVY_READ_STATEMENT_TIMEOUT_MS, POOL_SIZE, SCALE_ALERT_*).
config :loopctl, :rls_reroute_list_stories_by_project, false

# DI: Article category classifier for the reclassification backfill
# (KnowledgeReclassifyWorker). Overridden in test env.
# US-41.3: tenant-aware router (Claude or OpenAI-compatible sibling per tenant).
config :loopctl, :category_classifier, Loopctl.Knowledge.ClassifierRouter

# Reclassification backfill tunables (KnowledgeReclassifyWorker). Query-shaped,
# so they can also be passed per-kick in the job args.
config :loopctl,
  knowledge_reclassify_batch_size: 100,
  knowledge_reclassify_max_per_run: 1_000,
  knowledge_reclassify_min_confidence: 0.75,
  knowledge_reclassify_max_concurrency: 10,
  # Outage resilience: snooze (retry same cursor) when >= this fraction of a
  # batch fails to classify, instead of advancing past unreclassified articles.
  knowledge_reclassify_snooze_error_rate: 0.5,
  knowledge_reclassify_snooze_seconds: 60

# KnowledgeLintWorker orphan self-heal. Orphans (zero links) re-link at a LOWER
# threshold than the global 0.6: their nearest neighbor is typically a near-miss
# of 0.6, so re-linking at 0.6 would leave them isolated forever.
# max_orphan_relink caps how many orphans one nightly run acts on.
config :loopctl,
  knowledge_lint_orphan_link_threshold: 0.5,
  knowledge_lint_max_orphan_relink: 500

# Consolidation drain rates (#611). All three were previously pinned to module defaults sized
# for a class that had never applied anything in production. It has now: 112 loser articles
# unpublished on 2026-08-06 UTC, and ALL 112 were verified to still have a surviving published
# twin. The bounds stay — a bug that mis-picks winners must be visible after one night rather
# than after the whole corpus — but they are sized to CONVERGE rather than to hold a line.
#
# `max_per_class` at the hard ceiling means the report stops being permanently `truncated`,
# which matters because the two-run agreement gate can only confirm what BOTH reports carry:
# a standing backlog larger than the cap could never drain, however long it ran. At 100 the
# corpus sat at 290 proposals with 100 visible, i.e. a queue that converged to a floor rather
# than to zero.
#
# Unpublish is reversible by publishing, which is what licenses a bound this size at all.
#
# Both apply caps are clamped to 0..500 (500 is the hard ceiling — raising a value above it
# has no effect), and a non-integer value is ignored in favour of the module default. Setting
# either to 0 PAUSES the auto-unpublish drain for that run: nothing is applied and the audit
# event records duplicate_apply_gate=drain_disabled, so a paused night is not mistaken for a
# clean one. That is the supported way to halt the drain during an incident.
#
# knowledge_consolidation_min_duplicate_similarity is the CONTENT gate on the same class:
# the minimum pairwise cosine a title-collision group must reach before it may auto-apply.
# It lives here so all four levers on that pass are discoverable in one place. All four
# also resolve through a SystemConfig DB row first (the similarity one as the integer-percent
# key knowledge_consolidation_min_duplicate_similarity_pct, since SystemConfig stores
# integers), so an operator can move any of them without a deploy.
#
# NOTE the asymmetry on 0: for the three caps 0 is an explicit PAUSE, but for the similarity
# threshold 0 is REFUSED rather than honoured — min_sim >= 0.0 holds for every pair, so it
# would turn the only content check on the auto-applying class fully off, which is the
# opposite of what an operator typing 0 means.
config :loopctl,
  knowledge_consolidation_max_per_class: 500,
  knowledge_consolidation_max_applies: 500,
  knowledge_consolidation_max_unpublishes: 500,
  knowledge_consolidation_min_duplicate_similarity: 0.80

# LinkPruning (#611 stage 0): how many over-degree `relates_to` edges one nightly run may
# DELETE, worst-first. Sized to converge in a few nights rather than a few months — the
# standing backlog on the hosted corpus was ~903,600 edges (1,402,699 total, 499,058
# surviving union-kNN top-10) and the write-side cap means the producer no longer outruns
# the drain. The remainder is reported on the audit event and logged, never dropped
# silently. Only machine-derived, rankable `relates_to` rows are ever in scope.
config :loopctl, :knowledge_link_prune_max_per_run, 250_000

# KnowledgeMocWorker: corpus-specific tags to exclude from Map-of-Content
# generation (on top of the worker's generic structural/format/provenance list).
# These are source COLLECTIONS, not topics, so a per-tag MOC for them is noise.
config :loopctl, :knowledge_moc_excluded_tags, ~w(synology-docs synology-netbackup)

# Novelty-gated write-back (ProposalGate): cosine-similarity bands for an agent's
# proposed article vs. the published corpus. >= duplicate → reject in favour of the
# canonical article; >= overlap → route to a draft for the consumer to resolve;
# below → novel, created on the requested path.
config :loopctl, :knowledge_proposal_duplicate_threshold, 0.97
config :loopctl, :knowledge_proposal_overlap_threshold, 0.88

# Route-the-findings (#4): two published articles whose cosine similarity is at/above
# this are "too similar to comfortably coexist" — flagged with a `:potential_conflict`
# link for the consuming agent to resolve (merge a redundancy / reconcile a real
# contradiction). The KB only flags; it never judges which it is.
config :loopctl, :knowledge_conflict_threshold, 0.93

# Merge synthesizer (#4 step 2): the LLM that combines two articles a grounded agent
# marked `:merge` into ONE draft. Resolves the tenant's BYO Anthropic key per-tenant
# via Loopctl.Llm.resolve/2 (Epic 28, #179); drafts only.
# US-41.3: tenant-aware router (Claude or OpenAI-compatible sibling per tenant).
config :loopctl, :merge_synthesizer, Loopctl.Knowledge.MergeSynthesizerRouter
# Max `:relates_to`→`:potential_conflict` promotions the nightly lint sweep does per
# tenant per run (bounds the existing-corpus backfill; it cycles over nights).
config :loopctl, :knowledge_lint_max_conflict_promotions, 500

# DI: the nearest-neighbour similarity lookup Loopctl.Workers.ArticleLinkingWorker uses
# (Loopctl.Knowledge.SimilaritySearchBehaviour). Production/dev run the real
# index-correct pgvector kNN helper; config/test.exs swaps in a Mox mock so the worker's
# linking logic can be unit-tested deterministically off the timed heavy-read path.
config :loopctl, :article_similarity_search, Loopctl.Knowledge.VectorSearch

# Hybrid resolver (US-31.2): a curated candidate wins `:curated` ONLY when its
# `Knowledge.absolute_score/1` — the RAW cosine similarity_score (bounded 0..1) for a
# semantic match, or a bounded raw/(raw+1) transform of the raw ts_rank_cd
# relevance_score for a keyword match — clears this ABSOLUTE threshold AND beats the
# best retrieved candidate's absolute score by at least this margin (see
# Knowledge.resolve_provenance/4). This is NEVER final_score (a pool-relative,
# min-max-NORMALIZED 0..1 value built by merge_results/5 — a lone/top candidate in a
# sparse pool always normalizes to 1.0 regardless of its true similarity, which is
# exactly the false-confident-curated failure this threshold exists to prevent). A
# curated doc that is merely semantically near a query it doesn't answer must fall to
# `:retrieved`, never a false-authoritative claim (#305/#306).
#
# This pair is the SEMANTIC-scale (cosine similarity) threshold/margin. Cosine
# similarity and ts_rank_cd are different, incommensurable scales, so the
# KEYWORD-scale pair below is separate and must never be conflated with this one.
config :loopctl, :knowledge_hybrid_curated_threshold, 0.75
config :loopctl, :knowledge_hybrid_curated_margin, 0.1

# Hybrid resolver (US-31.2), KEYWORD scale: applied instead of the semantic-scale pair
# above when the winning curated candidate's absolute score comes from the bounded
# raw/(raw+1) transform of ts_rank_cd (a keyword-only match — see
# Knowledge.normalize_keyword_score/1), never the raw unbounded ts_rank_cd itself.
# Calibrated against real ts_rank_cd output: a confidently-matching, normal-length
# curated doc lands around ~0.67 after the transform, while a merely-incidental single
# mention deep in an unrelated document lands around ~0.29 — 0.5 cleanly separates the
# two with margin on both sides.
config :loopctl, :knowledge_hybrid_curated_threshold_keyword, 0.5
config :loopctl, :knowledge_hybrid_curated_margin_keyword, 0.1

# search_combined/3 lane fusion (#470). RRF (Reciprocal Rank Fusion) replaces the
# legacy min-max normalized weighted-sum: `score(doc) = Σ_lane weight_lane / (k +
# rank_lane(doc))`. RRF is rank-based, so it is immune to the incommensurable-scale
# problem (ts_rank_cd vs cosine similarity) that made min-max brittle, and the `k`
# smoothing constant makes cross-lane consensus outweigh one lane's single #1 vote.
# The legacy min-max path is kept behind `:min_max` for A/B and eval comparison.
# All are overridable per-call (opts) for tests/experiments — config-DI, never
# Application.put_env in tests.
config :loopctl, :knowledge_fusion_strategy, :rrf
# RRF smoothing constant. Default 60 per the canonical RRF formula (KB f4a10824).
config :loopctl, :knowledge_rrf_k, 60
# Third graph-neighbor lane (#470): one-hop link-graph neighbors of the top merged
# candidates fed into the fusion. Graph-only neighbors carry no relevance/similarity score
# (their hybrid-resolver absolute_score stays 0.0) and never inflate
# meta.semantic_result_count.
#
# ON since the Phase 5 retrieval experiment (see docs/research/kb-retrieval-improvement-
# plan.md). It shipped OFF because nothing could adjudicate it: the eval corpus seeded no
# `article_links` at all, so the lane was a strict no-op there and a lane-on run scored an
# identical, entirely uninformative delta. golden_v4 seeds real edges and adds multi-hop
# questions whose relevant document is reachable ONLY through one, at which point the
# measurement was decisive — see the weight comment below for the numbers.
#
# It costs one bounded, tenant-scoped HeavyRead per combined search (capped at
# 200 link rows), shed to an empty lane when the tenant is over its in-flight cap. That
# is a real added read on the DEFAULT search path, and it is the price of the recall gain.
config :loopctl, :knowledge_rrf_graph_lane_enabled, true
# Weight of the graph-neighbor lane in RRF fusion. 0.15, chosen by measurement rather than
# by the "comfortably below 0.5" argument that picked the original 0.25. Swept on golden_v4
# (embeddings arm, 60 questions), lane off as the reference:
#
#   weight | answered | mrr    | recall@5 | multi-hop answered | single-fact answers lost
#   off    | 45       | 0.6500 | 0.642    | 0 of 8             | -
#   0.10   | 47       | 0.6431 | 0.675    | 2                  | -
#   0.15   | 48       | 0.6492 | 0.692    | 3                  | -           <-- shipped
#   0.25   | 49       | 0.6326 | 0.717    | 5                  | q-liveview-mount
#   0.40   | 51       | 0.5992 | 0.750    | 7                  | q-liveview-mount
#
# The literature's warning is that graph retrieval WINS on multi-hop and LOSES on
# single-fact lookups, and that is exactly the shape of this curve. 0.15 is the largest
# weight that buys multi-hop recall while costing no question its answer: three single-fact
# questions drop in MRR, all keeping their answer inside the top 5. 0.25 buys two more
# multi-hop answers and takes one away from q-liveview-mount, which is the trade the plan's
# own pass/fail refuses ("no regression on single-fact ones"). Re-run the sweep with
# `mix loopctl.retrieval.eval --graph-lane --graph-weight <w>` before moving this number.
#
# STRICTLY BELOW the keyword/semantic per-lane weight (0.5 each) as well. The graph lane carries
# NO relevance/similarity signal (a neighbor surfaces only because it is link-adjacent to
# a seed), so it must never tie OR outrank a genuine single-lane hit. At the primary weight
# (0.5) a graph-rank-1 neighbor scores 0.5/(k+1) — EXACTLY equal to a single-lane rank-1
# hit — and the deterministic `{final_score, id}` desc tiebreak could then float a
# zero-signal neighbor with a larger id ABOVE the true top hit (#470 review). At 0.25 a
# graph-rank-1 neighbor scores 0.25/(k+1) < 0.5/(k+1), so the "never outranks a genuine
# single-lane top hit" invariant holds by construction, in POSITION not just in score. A
# doc that is ALSO a genuine hit still sums its primary-lane contribution, so real
# cross-lane consensus is unaffected. (That argument bounds the weight from above; it never
# said which value below the bound was right, which is what the sweep settles.)
config :loopctl, :knowledge_rrf_graph_weight, 0.15
# Number of top merged candidates used as graph-lane seeds (bounds link fan-out).
config :loopctl, :knowledge_rrf_graph_seed_count, 10
# Overall cap on distinct graph-lane neighbors injected into the fusion.
config :loopctl, :knowledge_rrf_graph_max_neighbors, 20

# Phase 4 second-stage reranking. OFF by default: it puts an outbound provider call on the
# DEFAULT search path, and the measurements that motivated the retrieval plan eliminate
# ranking as the cause of the injected channel's follow-through gap — so a better ranker
# improves something no measurement implicates. The seam exists so the experiment is
# runnable (`mix loopctl.retrieval.eval --rerank`) rather than argued about.
#
# It reorders the RETURNED PAGE, not the fused pool, so it can move recall below the page
# size and MRR/nDCG within it, and cannot move recall AT the page size.
config :loopctl, :knowledge_reranker_enabled, false
config :loopctl, :knowledge_reranker, Loopctl.Knowledge.Reranker.Noop

# search_combined/3 post-fusion ranking priors (#471, epic #468 — the Cerebras RAG
# playbook). Two priors re-rank the fused candidate list AFTER RRF/min-max fusion but
# BEFORE the top-k cut, and they also apply on the degraded keyword_only fallback (both
# need no embedding). They are POST-FUSION MULTIPLIERS on the fused `:final_score` (the
# RRF `Σ weight/(k+rank)` value), NOT the 0..1 relevance blend knowledge_context uses.
# All are overridable per-call via opts (config-DI; never Application.put_env in tests).
# Default-on in every env (no test override). The retrieval-eval baseline was regenerated
# with them enabled; on a like-for-like golden_v2 corpus (priors OFF vs ON) they improve
# every aggregate metric with no per-question regression — the lift is driven by recency
# (authority is net-inert on the synthetic eval corpus). See docs/runbooks/retrieval_eval.md.
#
# Recency uses the SAME exp(-age_days/30) decay as knowledge_context — single source of
# truth Loopctl.Knowledge.RankingPriors.recency_decay/2 — applied as the BOUNDED factor
# `1 - w + w*decay` on the fused score. Default weight 0.3 matches knowledge_context.
config :loopctl, :knowledge_recency_weight, 0.3
# Source-authority prior: toggle + magnitude. The factor is
# `clamp(1 + strength * (category_weight + source_type_weight + provenance_weight), 0.9, 1.1)`.
# The provenance term (#251) separates first-party knowledge from third-party HARVESTED
# material by the structural capture tag a sourcer stamps (`book-`/`url-`/`yt-`/`doc-`
# prefixes and the bare kind tags) — `source_type` cannot, because ~98% of the corpus
# carries a NULL one. It earns its place: measured 2026-08-11, first-party articles are read
# 26.7x more per article than harvested ones (389.7 vs 14.6 reads per 1k), and are 4% of the
# corpus but 53% of the reads. The weight is deliberately far smaller than that ratio —
# priors break near-ties here, they do not dominate relevance. Because every
# category/source_type/provenance weight is >= 0 and strength is >= 0, `1 + strength*(sum)` is
# always >= 1.0 — so the 0.9 floor is UNREACHABLE and the EFFECTIVE range is [1.0, 1.1].
# The band is one-sided BY DESIGN: authority only ever BOOSTS a higher-authority doc; it
# never demotes a low-authority raw note below neutral (demotion comes solely from the
# separate verdict-kill / :superseded 0.5 factor). The weight tables live in
# Loopctl.Knowledge.RankingPriors. Small and clamped so it only re-ranks near-ties (RRF
# ties by construction) and can never flip a cross-lane-consensus winner (~2x a single-lane
# hit). verdict-kill ideas and :superseded articles are demoted regardless of this toggle.
config :loopctl, :knowledge_authority_prior_enabled, true
config :loopctl, :knowledge_authority_strength, 0.05

# MOC/index-hub demotion (#654 follow-up). Generated "Index: <tag>" hubs are navigation,
# not answers: on the live corpus one was rank 1 for 12% of real questions while the whole
# hub set was opened once. Hub-ness is read from the worker's own `idempotency_key`
# ("moc:<tag>"), never from tags — `tags` is agent-writable via knowledge_update, so a
# tag-derived penalty let any agent halve ANOTHER agent's rank. This switch exists because
# the inference is corpus-wide: a tenant whose MOC output IS what its agents want to read
# turns the penalty off here without a deploy. Dead doctrine (verdict-kill / :superseded)
# is demoted regardless — that one is not a matter of taste.
config :loopctl, :knowledge_hub_demotion_enabled, true

# DI: WebAuthn adapter — defaults to Wax (overridden in test env)
config :loopctl, :webauthn_adapter, Loopctl.WebAuthn.Wax

# WebAuthn relying party configuration. `rp_id` must match the host the
# signup LiveView is served from. Overridden in dev and prod as needed.
config :loopctl, :webauthn,
  rp_id: "loopctl.com",
  # US-26.7.2: rp_name is served by the stateless enrollment-challenge API
  # endpoint (POST /tenants/:id/authenticators/challenge) so the relying
  # party display name comes from server config, not a hard-coded JS client.
  rp_name: "loopctl",
  origin: "https://loopctl.com",
  user_verification: "preferred"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
