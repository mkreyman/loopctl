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
  # Cosine similarity threshold for auto-linking articles.
  # 0.6 is calibrated for relationship discovery (related topics).
  # 0.8+ is only useful for near-duplicate detection.
  article_link_threshold: 0.6,
  article_link_max_comparisons: 50,
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
  # :suggested_links, :semantic_search, :distant_pairs, :novelty, :enumeration,
  # :change_feed, :vector_search. NOTE: :distant_pairs,
  # :semantic_search, and :enumeration each issue TWO reads (count + data); setting an
  # override for any of them wraps EACH read in its own separate transaction, doubling
  # the brief checkout count on the heavy pool. :change_feed (US-27.9b) is the
  # rate-limited orchestrator polling feed — a SINGLE cheap keyset read per request;
  # its QPS is bounded by the api pipeline's rate limiter, so it adds at most a brief,
  # fast-releasing checkout and does not erode the K≈6 one-shot fast-read budget.
  heavy_read_statement_timeout_overrides: %{},
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
  #   :test never runs its timers / owns its ETS table); turned ON in prod (runtime.exs).
  # - scale_alert_webhook_url: the operator webhook (Slack/PagerDuty/generic). nil =
  #   alerting OFF (opt-in) — a breach is logged, nothing is POSTed. Set in runtime.exs
  #   from SCALE_ALERT_WEBHOOK_URL.
  # - scale_alert_check_interval_ms: how often the tumbling window is evaluated + reset.
  # - scale_alert_window_ms: the window length (defaults to the check interval) — used to
  #   turn counts into per-minute rates and to report window_seconds in the payload.
  # - the three thresholds (documented defaults): timeouts/min, p95 heavy-read ms,
  #   under-fill events/min. Edge-triggered debounce: an alert fires on the transition
  #   INTO breach, re-arming once the metric clears (no per-interval spam).
  scale_alerts_enabled: false,
  scale_alert_webhook_url: nil,
  scale_alert_check_interval_ms: 60_000,
  scale_alert_timeout_rate_per_min: 5,
  scale_alert_p95_latency_ms: 2_000,
  scale_alert_under_fill_rate_per_min: 30

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
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

# Oban background jobs
config :loopctl, Oban,
  repo: Loopctl.Repo,
  queues: [
    default: 10,
    webhooks: 5,
    cleanup: 2,
    analytics: 3,
    maintenance: 2,
    embeddings: 5,
    knowledge: 5,
    audit: 3
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Loopctl.Workers.IdempotencyCleanupWorker},
       {"0 * * * *", Loopctl.Workers.BulkDeleteTokenCleanupWorker},
       {"0 2 * * *", Loopctl.Workers.AuditPartitionWorker},
       {"0 2 * * *", Loopctl.Workers.CostRollupWorker},
       {"0 3 * * *", Loopctl.Workers.WebhookCleanupWorker},
       {"0 3 * * 0", Loopctl.Workers.TokenDataArchivalWorker},
       {"0 4 * * *", Loopctl.Workers.KnowledgeLintWorker, args: %{"mode" => "all_tenants"}},
       {"0 5 * * 0", Loopctl.Workers.KnowledgeMocWorker, args: %{"mode" => "all_tenants"}},
       {"*/5 * * * *", Loopctl.Workers.PendingEnrollmentCleanupWorker},
       {"* * * * *", Loopctl.Workers.ComputeSthWorker, args: %{"mode" => "all_tenants"}},
       {"* * * * *", Loopctl.Workers.RevokeExpiredDispatchesWorker}
     ]}
  ]

# Cloak Vault — key configured per environment
# Generate a key: :crypto.strong_rand_bytes(32) |> Base.encode64()
# The actual cipher is set in config/runtime.exs (prod) or config/test.exs (test).
# Default is empty — prod will raise at startup if CLOAK_KEY is not set.
config :loopctl, Loopctl.Vault,
  ciphers: [],
  retired_ciphers: [
    # Add previous keys here during key rotation, e.g.:
    # {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V0", key: Base.decode64!("OLD_KEY"), iv_length: 12}
  ]

# DI: Content extractor for knowledge ingestion
config :loopctl, :content_extractor, Loopctl.Knowledge.ClaudeContentExtractor

# DI: Article category classifier for the reclassification backfill
# (KnowledgeReclassifyWorker). Overridden in test env.
config :loopctl, :category_classifier, Loopctl.Knowledge.ClaudeCategoryClassifier

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

# KnowledgeMocWorker: corpus-specific tags to exclude from Map-of-Content
# generation (on top of the worker's generic structural/format/provenance list).
# These are source COLLECTIONS, not topics, so a per-tag MOC for them is noise.
config :loopctl, :knowledge_moc_excluded_tags, ~w(synology-docs synology-netbackup)

# DI: WebAuthn adapter — defaults to Wax (overridden in test env)
config :loopctl, :webauthn_adapter, Loopctl.WebAuthn.Wax

# WebAuthn relying party configuration. `rp_id` must match the host the
# signup LiveView is served from. Overridden in dev and prod as needed.
config :loopctl, :webauthn,
  rp_id: "loopctl.com",
  origin: "https://loopctl.com",
  user_verification: "preferred"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
