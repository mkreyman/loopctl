import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/loopctl start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :loopctl, LoopctlWeb.Endpoint, server: true
end

# US-38.2 (Epic 38, GH #353): OPT-IN cluster-global rate limiter.
#
# The `:rate_limiter` behaviour impl defaults to node-local ETS
# (`Loopctl.RateLimiter.Hammer`) — set nowhere, so callers fall back to it —
# which means any global limit becomes `limit × node_count` across a cluster.
# Setting `RATE_LIMITER=postgres` selects the shared Postgres-backed impl so the
# web RPM plug, `Loopctl.Provider.Admission`, and the signup/enroll/retrieve
# gates all enforce ONE cluster-wide budget with no code change. UNSET (or any
# other value) leaves today's exact node-local ETS behaviour untouched. This
# provisions NOTHING — the counter table already ships in a migration; the env
# var only flips which behaviour impl the DI resolves. Never set to a
# placeholder value (epic_35 STH_SWEEP_CRON lesson).
#
# Operational caveats when enabling (see Loopctl.RateLimiter.Postgres moduledoc):
#   * Fail-open blast radius broadens to every caller. Capacity gates (RPM plug,
#     retrieve, provider admission) stay fail-OPEN on a DB fault; the anti-abuse /
#     brute-force SECURITY gates (signup abuse, WebAuthn-verify, enroll) use
#     `Loopctl.RateLimiter.gate_ok?/3` and fail-CLOSED, so a DB fault cannot
#     silently unlock them.
#   * `check_rate/3` runs a single upsert via the BYPASSRLS `Loopctl.AdminRepo`
#     on every authenticated request — size/monitor the AdminRepo pool, and note
#     the hottest bucket's single row is a serialization + autovacuum-bloat point.
if System.get_env("RATE_LIMITER") == "postgres" do
  config :loopctl, :rate_limiter, Loopctl.RateLimiter.Postgres
end

# sec-4: OPT-IN override of the coarse per-IP auth-path throttle ceiling/window
# (`LoopctlWeb.Plugs.AuthPathThrottle`). Unlike the tenant-overridable per-KEY
# limit, this per-IP ceiling is a single global knob; these env vars are its
# zero-redeploy operational remedy (e.g. raising it above the largest configured
# per-tenant aggregate, or for a shared-egress/NAT deployment where many
# legitimate keys share one outbound IP). Only a valid POSITIVE integer is
# applied — an unset/blank/garbage value is ignored so a bad placeholder can
# NEVER crash release boot (epic_35 STH_SWEEP_CRON lesson); the plug itself also
# floors to its default on a non-positive value.
auth_throttle_opts =
  [
    max_requests_per_ip: System.get_env("AUTH_THROTTLE_MAX_REQUESTS_PER_IP"),
    window_ms: System.get_env("AUTH_THROTTLE_WINDOW_MS")
  ]
  |> Enum.flat_map(fn {key, raw} ->
    case raw && Integer.parse(raw) do
      {n, ""} when n > 0 -> [{key, n}]
      _ -> []
    end
  end)

if auth_throttle_opts != [] do
  config :loopctl, LoopctlWeb.Plugs.AuthPathThrottle, auth_throttle_opts
end

endpoint_http = [
  # Transport-layer DoS backstop. `websocket_options` is a BANDIT server-level
  # setting (the Phoenix `socket "/live", websocket: [...]` DSL rejects
  # :max_fragmented_message_size). It caps a REASSEMBLED (multi-frame) websocket
  # message; the socket DSL `max_frame_size: 64_000` caps a single frame.
  # Without this, N sub-64KB continuation frames reassemble into one message up
  # to Bandit's 8 MB default, bypassing the per-frame cap.
  websocket_options: [max_fragmented_message_size: 64_000]
]

# PORT overrides the env-specific default (dev.exs pins 4030; prod must set PORT —
# fly.toml sets 8080). Applied only when present so this all-envs block does not
# clobber the per-app dev port with the old Phoenix-default 4000.
endpoint_http =
  case System.get_env("PORT") do
    nil -> endpoint_http
    port -> Keyword.put(endpoint_http, :port, String.to_integer(port))
  end

config :loopctl, LoopctlWeb.Endpoint, http: endpoint_http

# Oban queue widths are env-driven (US-32.2) so an operator can retune a hot/starved
# queue during an incident via `fly secrets set OBAN_QUEUE_<NAME>` + restart, no deploy.
# Each defaults to its config.exs value when unset. NB: total worker concurrency (sum of
# widths, default 38) shares the Repo pool (POOL_SIZE, default 10 — see the Repo config
# below and `Loopctl.DbCapacity`). Widths far above the connection budget will queue on
# checkout; operators own this tradeoff — no hard cap is enforced here. This runs in
# EVERY env (not just prod) so defaults hold under `testing: :inline` (config/test.exs)
# with zero env vars required; Elixir `Config` DEEP-MERGES the `queues:` keyword list
# with the compile-time one (a queue key present in config.exs but omitted here would
# be preserved, not dropped), but `Loopctl.ObanConfig.queues/0` always re-lists every
# default queue anyway so the env-tunability guarantee holds unconditionally.
#
# US-35.3: the Oban `:plugins` list (Cron crontab + Lifeline + Pruner + Reindexer) is
# ALSO owned here, via `Loopctl.ObanConfig.plugins/0`, so the all-tenants
# ComputeSthWorker safety-sweep schedule is driven by `STH_SWEEP_CRON` and is
# tunable/revertible per environment without a deploy. Unlike `queues:` (a keyword list
# `Config` deep-merges), `:plugins` is a plain list `Config` REPLACES wholesale — so it
# must be set from a single owner (here). `config/config.exs` no longer sets `plugins:`.
config :loopctl, Oban,
  queues: Loopctl.ObanConfig.queues(),
  plugins: Loopctl.ObanConfig.plugins()

# US-36.2: validate the per-tenant fair-share knobs (OBAN_TENANT_FAIRSHARE_<QUEUE> caps
# + SNOOZE base/jitter) at BOOT, alongside the queue widths above. Evaluating
# `fair_share_config/0` calls each knob's parser, which RAISES on a present-but-malformed
# value — so a fat-fingered cap aborts the node LOUD here (like a bad OBAN_QUEUE_*),
# instead of surfacing only at gate call-time where the count path fails OPEN and would
# silently disable fairness on that queue. Stored so the resolved boot config is
# introspectable; the gate itself re-reads env at call time (config-based DI).
config :loopctl, :fair_share_config, Loopctl.ObanConfig.fair_share_config()

# US-36.3: validate the batch-ingest backlog knob (OBAN_INGEST_BACKLOG_MAX) at BOOT,
# alongside the fair-share knobs above and the queue widths. `ingest_backlog_max/0`
# calls `queue_size/2`, which RAISES on a present-but-malformed value — so a
# fat-fingered live-tuning typo aborts the node LOUD here (like a bad OBAN_QUEUE_* or
# OBAN_TENANT_FAIRSHARE_*), instead of surfacing only at CALL time as a stream of
# per-request 500s on the batch-ingest endpoint at the worst possible moment. Stored so
# the resolved boot value is introspectable; the gate re-reads env at call time
# (config-based DI).
config :loopctl, :ingest_backlog_max, Loopctl.ObanConfig.ingest_backlog_max()

# US-36.3 (review): validate the backlog-429 Retry-After knob
# (OBAN_INGEST_BACKLOG_RETRY_AFTER) at BOOT too, same rationale as the threshold above —
# a fat-fingered value aborts the node LOUD here instead of surfacing as per-request 500s
# on the ingest endpoints. Stored so the resolved boot value is introspectable; the gate
# re-reads env at call time (config-based DI).
config :loopctl,
       :ingest_backlog_retry_after_seconds,
       Loopctl.ObanConfig.ingest_backlog_retry_after_seconds()

# Cloak Vault — key from environment in all environments where CLOAK_KEY is set.
# In production, CLOAK_KEY is required — startup fails if it is missing.
if config_env() == :prod do
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: :crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()
      """

  config :loopctl, Loopctl.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
      }
    ]
else
  if cloak_key = System.get_env("CLOAK_KEY") do
    config :loopctl, Loopctl.Vault,
      ciphers: [
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
        }
      ]
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :loopctl, Loopctl.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    connect_timeout: 15_000,
    queue_target: 5_000,
    queue_interval: 10_000

  # AdminRepo — same database, different role with BYPASSRLS in production
  admin_database_url =
    System.get_env("ADMIN_DATABASE_URL") || database_url

  # REPLICA_DATABASE_URL (US-38.1) — read DSN for the HeavyReadRepo pool. DEFAULTS OFF:
  # when UNSET it falls back to `admin_database_url`, mirroring the ADMIN_DATABASE_URL
  # fallback pattern above EXACTLY, so today's behaviour is byte-for-byte identical
  # (heavy reads still hit the primary's BYPASSRLS role). Resolved through the pure
  # `Loopctl.DbCapacity.resolve_replica_url/2` so the resolution is unit-testable
  # (runtime.exs is prod-only and never reflected by Application.get_env under `mix test`).
  #
  # FUTURE GATED INFRA OP: setting REPLICA_DATABASE_URL is a deliberate, gated operation —
  # it MUST point at a BYPASSRLS read-role DSN with the SAME capabilities as today's admin
  # role (role parity), on a real read replica. No infra is provisioned by this config; if
  # the DSN is unreachable the HeavyReadRepo pool fails LOUD at boot (it never establishes a
  # connection) rather than silently falling back to the primary — that is intentional.
  replica_database_url =
    Loopctl.DbCapacity.resolve_replica_url(
      System.get_env("REPLICA_DATABASE_URL"),
      admin_database_url
    )

  # DbCapacity models a replica connection dimension only when a DISTINCT replica DSN is
  # configured. Unset (or set equal to the primary) → false → the connection budget math is
  # unchanged from today.
  config :loopctl,
         :replica_database_url_configured,
         replica_database_url != admin_database_url

  config :loopctl, Loopctl.AdminRepo,
    url: admin_database_url,
    pool_size: String.to_integer(System.get_env("ADMIN_POOL_SIZE") || "3"),
    socket_options: maybe_ipv6,
    connect_timeout: 15_000,
    queue_target: 5_000,
    queue_interval: 10_000

  # HeavyReadRepo (US-27.11) — dedicated BYPASSRLS pool for heavy vector/enumeration
  # reads, isolated from the small AdminRepo pool so a slow read can't starve light
  # admin ops (and vice-versa).
  #
  # The server-side `statement_timeout` is applied PER-READ via `SET LOCAL` inside the
  # HeavyRead transaction path (Loopctl.HeavyRead.opts/1 → all/one → transaction/2),
  # NOT as a connection startup `:parameter`. This is load-bearing: Fly MPG fronts
  # Postgres with pgbouncer, which allows only an allowlisted set of startup parameters
  # and REJECTS a `statement_timeout` startup parameter with
  # `FATAL 08P01 unsupported startup parameter: statement_timeout`. Setting it via
  # `:parameters` crash-loops EVERY HeavyReadRepo connection (the pool never establishes
  # one) and 503/504s every heavy endpoint (suggested_links, semantic search,
  # distant_pairs, novelty, heavy enumeration). `SET LOCAL` inside a transaction is the
  # pgbouncer-safe path and is verified to enforce against the live pool. Likewise the
  # pgvector custom GUC `hnsw.ef_search` is NOT settable via :parameters on managed PG — it
  # is applied per-ANN-read via `SET LOCAL hnsw.ef_search` inside that SAME heavy-read
  # transaction (US-38.4), configured live via the SystemConfig `hnsw_ef_search` key
  # (default 40) — emitted ONLY when that value differs from the pgvector default. Because a
  # `SET LOCAL` overrides any role/session default for its transaction, a role-level
  # `ALTER ROLE <role> SET hnsw.ef_search` lever still works AND is honored whenever
  # SystemConfig is left at the default (the per-read SET LOCAL never shadows it); a
  # non-default SystemConfig value wins per-read. See docs/runbooks/knowledge-scale.md.
  #
  # Pool sizes here MUST stay in lockstep with `Loopctl.DbCapacity` (which models the
  # connection budget and is asserted in db_capacity_test.exs). Sizing (AC-27.11.1/.5),
  # vs the live fly mpg max_connections = 100 (runbook re-verifies post-deploy):
  #   per-node: Repo 10 + AdminRepo 3 + HeavyReadRepo 8 = 21; peak during a rolling
  #   deploy at 2 nodes = 42 + 21 (overlap node) + 4 ops = 67 < 100 (max ~3 nodes).
  #
  # US-33.6 (re-derived — no rebalance shipped): the AdminRepo/Repo split above is
  # UNCHANGED from US-27.11. The original rebalance candidate ("every authenticated
  # request runs ~5 AdminRepo queries on the 3-conn BYPASSRLS pool while Repo sits
  # idle, so shift Repo 10 -> 7 / AdminRepo 3 -> 6") does NOT hold against the
  # CURRENT codebase and was reverted before merge:
  #   * US-33.3 (`Loopctl.Auth.ApiKeyCache`, ETS read-through api-key cache) + US-33.4
  #     (`Loopctl.TouchBuffer`, debounced last_used_at writes) already landed on this
  #     branch's base and together cut the auth hot path's per-request AdminRepo cost
  #     from ~5 statements down to ~1 — NOT to zero. The `:authenticated` pipeline's
  #     `ValidateWitnessHeader` plug still issues one uncached, cheap indexed STH
  #     SELECT per well-formed request (`AuditChain.get_sth_at_position/2` ->
  #     `AdminRepo.one/1`); ApiKeyCache's "net ZERO" moduledoc claim is scoped to the
  #     api-key TOUCH path only, not the whole pipeline. A cold-cache node (mid rolling
  #     deploy) additionally hits AdminRepo on every api-key-cache miss until warm —
  #     precisely the peak-budget overlap window this comment sizes against. So
  #     AdminRepo still carries real per-request load; watch
  #     `loopctl.admin_repo.checkout.queue_time` before trusting that 3 conns has
  #     headroom to spare.
  #   * The Repo pool is NOT idle: `Loopctl.ObanConfig` queue widths sum to 38 (see
  #     the comment above) and Oban checks out from THIS pool (`config/config.exs`
  #     `repo: Loopctl.Repo`), on top of web RLS traffic — cutting it 10 -> 7 would
  #     have tightened an already Oban-shared pool for no measured benefit.
  # US-33.1's per-pool checkout-wait telemetry
  # (loopctl.repo.checkout.queue_time / loopctl.admin_repo.checkout.queue_time) is
  # live but not yet conclusively populated in prod, so — per the story's own
  # guidance to resize from data, not guesswork — sizes are left at their US-27.11
  # defaults.
  #
  # EXPLICIT SCOPE DECISION (US-33.6 closes with zero pool-size change): re-derived;
  # no rebalance warranted against the CURRENT codebase. Residual AdminRepo load is
  # ~1 cheap indexed STH SELECT/request (not zero — see above) plus cold-cache
  # api-key-miss load during deploys; Repo is provably not idle (Oban's 38-wide
  # queue concurrency shares it). This is a deliberate re-scope of the story's
  # "rebalance" premise, not an automatic by-design close — revisit with a real
  # rebalance once US-33.1's checkout-wait telemetry populates in prod and points
  # in a specific direction.
  # K (HeavyReadRepo, default 8): ~6 concurrent sub-2s heavy vector reads + ~2 reserved
  # for long-held streamed-export checkouts (US-27.16), a different profile than fast reads.
  # Parse to an integer so a garbage/typo value (e.g. "10s", "10,000") fails LOUDLY at boot
  # (a deploy-time misconfiguration guard) rather than silently degrading. Postgres reads a
  # bare integer as milliseconds, matching the `_MS` env name. NB: this value is now applied
  # per-read via `SET LOCAL` (US-27.13), NOT a startup packet — `HeavyRead.opts/1` reads it
  # and `HeavyRead.default_statement_timeout/0` additionally fails SOFT (falls back to 10s) on
  # a bad app-env value, so the boot-raise here is the strict outer guard.
  heavy_read_statement_timeout_ms =
    String.to_integer(System.get_env("HEAVY_READ_STATEMENT_TIMEOUT_MS") || "10000")

  # Consumed by Loopctl.HeavyRead.opts/1 as the DEFAULT server-side statement_timeout
  # for any heavy endpoint without a per-endpoint override — applied via SET LOCAL on
  # the read path (pgbouncer-safe), replacing the rejected startup `:parameters` lever.
  config :loopctl, :heavy_read_statement_timeout_ms, heavy_read_statement_timeout_ms

  # Slow-query logging threshold (US-27.4). Parse to integer for the same reason —
  # garbage values fail loudly at boot. Default 1000ms.
  slow_query_threshold_ms =
    String.to_integer(System.get_env("SLOW_QUERY_THRESHOLD_MS") || "1000")

  config :loopctl, :slow_query_threshold_ms, slow_query_threshold_ms

  # US-33.7 — Flag-guarded RLS-Repo reroute pilot (AC-33.7.5). Read at RUNTIME from an
  # env var so flipping the pilot ON, or rolling it back, is an env-var change + restart
  # with NO release rebuild/redeploy. Overrides the compile-time OFF default in
  # config/config.exs. Truthy values: "true" or "1" (anything else, incl. unset, is OFF).
  # Kept OFF until the prod `Repo` role is verified to lack BYPASSRLS (AC-33.7.4).
  config :loopctl,
         :rls_reroute_list_stories_by_project,
         System.get_env("RLS_REROUTE_LIST_STORIES_BY_PROJECT") in ~w(true 1)

  # US-27.15: enable the supervised Prometheus reporter in prod. It binds the
  # INTERNAL `:9568/metrics` port (NEVER the public 8080 http_service) which Fly's
  # managed Prometheus scrapes over the private 6PN network (see the fly.toml
  # `[metrics]` block). The port is tunable via METRICS_PORT but MUST stay in lockstep
  # with fly.toml. The tenant-label cap is tunable via METRICS_TENANT_LABEL_CAP — keep
  # it bounded (the `tenant_id` counter label collapses to a sentinel above the cap to
  # keep label cardinality from blowing up across a large tenant fleet).
  config :loopctl, :metrics_reporter_enabled, true
  config :loopctl, :metrics_port, String.to_integer(System.get_env("METRICS_PORT") || "9568")

  config :loopctl,
         :metrics_tenant_label_cap,
         String.to_integer(System.get_env("METRICS_TENANT_LABEL_CAP") || "1000")

  # US-27.15 (AC-27.15.2): the FIRING alert path. ScaleAlerts is cheap (it only POSTs
  # when a webhook URL is set AND a threshold breaches), so start it in prod always; it
  # is opt-in until SCALE_ALERT_WEBHOOK_URL is configured (no URL → breaches are logged,
  # nothing is POSTed). Point SCALE_ALERT_WEBHOOK_URL at a Slack/PagerDuty/generic
  # incoming webhook. Thresholds default to the documented values and are tunable per
  # environment via env vars (per-minute rates / ms). The alert payload is id-only — no
  # tenant content / vectors / SQL.
  config :loopctl, :scale_alerts_enabled, true
  config :loopctl, :scale_alert_webhook_url, System.get_env("SCALE_ALERT_WEBHOOK_URL")

  config :loopctl,
         :scale_alert_check_interval_ms,
         String.to_integer(System.get_env("SCALE_ALERT_CHECK_INTERVAL_MS") || "60000")

  config :loopctl,
         :scale_alert_timeout_rate_per_min,
         String.to_integer(System.get_env("SCALE_ALERT_TIMEOUT_RATE_PER_MIN") || "5")

  config :loopctl,
         :scale_alert_p95_latency_ms,
         String.to_integer(System.get_env("SCALE_ALERT_P95_LATENCY_MS") || "2000")

  config :loopctl,
         :scale_alert_under_fill_rate_per_min,
         String.to_integer(System.get_env("SCALE_ALERT_UNDER_FILL_RATE_PER_MIN") || "30")

  # US-34.5 (AC-34.5.2): bounded periodic re-notify interval while a breach stays
  # sustained. `ScaleAlerts.renotify_interval_ms/0` floors this at 60_000ms, so a
  # misconfigured near-zero value can't turn re-notify into per-tick spam.
  config :loopctl,
         :scale_alert_renotify_interval_ms,
         String.to_integer(System.get_env("SCALE_ALERT_RENOTIFY_INTERVAL_MS") || "900000")

  # US-34.3: three additional ScaleAlerts signals — Repo checkout queue_time p95
  # (ms), fleet-wide Oban discard/retry rate (events/min), and LLM/embedding
  # provider-error rate (events/min). Same tunable-per-environment pattern as the
  # original three thresholds above.
  config :loopctl,
         :scale_alert_queue_time_p95_ms,
         String.to_integer(System.get_env("SCALE_ALERT_QUEUE_TIME_P95_MS") || "500")

  config :loopctl,
         :scale_alert_oban_discard_rate_per_min,
         String.to_integer(System.get_env("SCALE_ALERT_OBAN_DISCARD_RATE_PER_MIN") || "10")

  config :loopctl,
         :scale_alert_provider_error_rate_per_min,
         String.to_integer(System.get_env("SCALE_ALERT_PROVIDER_ERROR_RATE_PER_MIN") || "10")

  # `url:` resolves to REPLICA_DATABASE_URL when set, else admin_database_url (US-38.1).
  # When REPLICA_DATABASE_URL is UNSET this is byte-identical to `admin_database_url` —
  # the exact value HeavyReadRepo used before this story. `prepare: :unnamed` (on the repo
  # module) and the per-read SET LOCAL statement_timeout (Loopctl.HeavyRead.opts/1) are the
  # pgbouncer-safe mechanisms and are PRESERVED on the replica path — do NOT add a
  # `:parameters` startup param here (see the pgbouncer note below).
  config :loopctl, Loopctl.HeavyReadRepo,
    url: replica_database_url,
    pool_size: String.to_integer(System.get_env("HEAVY_READ_POOL_SIZE") || "8"),
    socket_options: maybe_ipv6,
    connect_timeout: 15_000,
    queue_target: 5_000,
    queue_interval: 10_000

  # NOTE: no `parameters: [statement_timeout: ...]` here — pgbouncer rejects it (08P01).
  # The timeout is enforced per-read via SET LOCAL (HeavyRead.opts/1). See the comment
  # above and config_pgbouncer_safe_parameters_test.exs (the regression guard).

  # OpenAI-compatible embedding provider for semantic search (Knowledge Wiki).
  #
  # BYO (#294 extended to embeddings): the embedding KEY is PER-TENANT — each tenant
  # supplies its OWN key via `PATCH /tenants/me/llm-config` (stored encrypted, resolved
  # by `Loopctl.Llm.resolve(tenant_id, :embedding)`). There is intentionally NO global
  # operator key here — that was the ungated, operator-funded spend path this change
  # closes. Only the shared ENDPOINT (base_url) + default model live in global config;
  # a tenant without a configured key simply gets NO embeddings.
  config :loopctl, :embedding_provider, %{
    base_url: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1",
    model: System.get_env("OPENAI_EMBEDDING_MODEL") || "text-embedding-3-small"
  }

  # US-41.4 (AC-41.4.5 / AC-41.4.9) — the OPERATOR-controlled deployment
  # allowlist: the ONLY thing that can carve specific hosts/CIDRs out of
  # `Loopctl.Net.UrlGuard`'s loopback/private/CGNAT/link-local/Fly-6PN denylist.
  # It is DEPLOYMENT-scoped, lives outside RLS, and is READ-ONLY at every role
  # including :user — there is deliberately no API path that mutates it. Tenant
  # declarations carve NOTHING out; they only change the locality VERDICT for
  # hosts that already pass the denylist.
  #
  #   LOCAL_ENDPOINT_ALLOWLIST="127.0.0.1,localhost,ollama.internal,10.1.0.0/16"
  config :loopctl,
         :local_endpoint_allowlist,
         (System.get_env("LOCAL_ENDPOINT_ALLOWLIST") || "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))

  # NOTE (Epic 28, #179): the global `:anthropic_provider` / `:knowledge_classifier_model`
  # config keys were REMOVED. Tenant knowledge-LLM work (content extraction,
  # classification, merge synthesis, review extraction) now resolves each tenant's
  # OWN Anthropic key + per-operation model via `Loopctl.Llm.resolve/2` (mandatory
  # BYO — no global-system-key fallback). There is intentionally no global
  # ANTHROPIC_API_KEY path for tenant LLM work.

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :loopctl, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :loopctl, LoopctlWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :loopctl, LoopctlWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :loopctl, LoopctlWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
