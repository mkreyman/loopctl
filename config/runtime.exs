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

config :loopctl, LoopctlWeb.Endpoint,
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    # Transport-layer DoS backstop. `websocket_options` is a BANDIT server-level
    # setting (the Phoenix `socket "/live", websocket: [...]` DSL rejects
    # :max_fragmented_message_size). It caps a REASSEMBLED (multi-frame) websocket
    # message; the socket DSL `max_frame_size: 64_000` caps a single frame.
    # Without this, N sub-64KB continuation frames reassemble into one message up
    # to Bandit's 8 MB default, bypassing the per-frame cap.
    websocket_options: [max_fragmented_message_size: 64_000]
  ]

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
  # pgbouncer-safe path and is verified to enforce against the live pool. Likewise
  # `ef_search` is NOT settable via :parameters on managed PG (a pgvector custom GUC);
  # see docs/runbooks/knowledge-scale.md for the ALTER ROLE mechanism if it must change.
  #
  # Pool sizes here MUST stay in lockstep with `Loopctl.DbCapacity` (which models the
  # connection budget and is asserted in db_capacity_test.exs). Sizing (AC-27.11.1/.5),
  # vs the live fly mpg max_connections = 100 (runbook re-verifies post-deploy):
  #   per-node: Repo 10 + AdminRepo 3 + HeavyReadRepo 8 = 21; peak during a rolling
  #   deploy at 2 nodes = 42 + 21 (overlap node) + 4 ops = 67 < 100 (max ~3 nodes).
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

  config :loopctl, Loopctl.HeavyReadRepo,
    url: admin_database_url,
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
