import Config

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
  pool_size: System.schedulers_online() * 2

# AdminRepo — same database, sandbox mode for tests
config :loopctl, Loopctl.AdminRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loopctl_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Scale tests seed ~80k rows under Sandbox.unboxed_run/2, which can exceed the
  # default 60s ownership timeout (the seed takes >2 min) → "owner process crashed".
  # Allow the unboxed connection to be held long enough for the prod-floor seed.
  ownership_timeout: :timer.minutes(30)

# HeavyReadRepo (US-27.11) — sandbox mode for tests, with a deliberately LOW
# pool-level statement_timeout (250ms) so the mechanism tests (SHOW + fast-fire)
# are fast and deterministic. Nothing in the default suite routes heavy DATA reads
# here — `:heavy_read_repo` below points heavy reads at AdminRepo so they share the
# sandbox connection fixtures insert through; only the dedicated HeavyReadRepo pool
# tests touch this repo directly.
config :loopctl, Loopctl.HeavyReadRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loopctl_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  ownership_timeout: :timer.minutes(30),
  # Bare-integer ms (the format the prod path ships, validated in runtime.exs); a low
  # 250ms so the fast-fire mechanism tests are sub-second. Postgres normalizes the
  # display to "250ms" (asserted in heavy_read_repo_test).
  parameters: [statement_timeout: "250"]

# DI (US-27.11): route Loopctl.HeavyRead's heavy reads to AdminRepo in tests, so
# they see the same sandbox transaction that fixtures write to. Prod/dev default to
# the dedicated Loopctl.HeavyReadRepo pool.
config :loopctl, :heavy_read_repo, Loopctl.AdminRepo

# US-27.4: TC-27.4.1 integration test — set a low statement_timeout override
# for suggested_links to make timeout tests fast and deterministic. Harmless
# for normal tests (the timeout is much longer than any real query).
config :loopctl, :heavy_read_statement_timeout_overrides, %{suggested_links: 5_000}

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :loopctl, LoopctlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QO3UeePU6EXaPNWZRMdH5lL+t+XQNelN9GHOJKhFgp8FEtjlvGzWWXoMiQI1EOE3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

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

# DI: Use mock rate limiter in tests
config :loopctl, :rate_limiter, Loopctl.MockRateLimiter

# DI: Use mock clock in tests
config :loopctl, :clock, Loopctl.MockClock

# DI: Use mock cost rollup in tests
config :loopctl, :cost_rollup, Loopctl.MockCostRollup

# DI: Use mock token archival in tests
config :loopctl, :token_archival, Loopctl.MockTokenArchival

# DI: Use mock embedding client in tests
config :loopctl, :embedding_client, Loopctl.MockEmbeddingClient

# DI: Use mock knowledge extractor in tests
config :loopctl, :knowledge_extractor, Loopctl.MockExtractor

# DI: Use mock content extractor in tests
config :loopctl, :content_extractor, Loopctl.MockContentExtractor

# DI: Use mock WebAuthn adapter in tests
config :loopctl, :webauthn_adapter, Loopctl.MockWebAuthn

# Full-content (include_body) byte budget — small in tests so the byte-budget
# truncation/continuation behavior can be exercised with a few small bodies
# instead of ~5 MB of fixtures (production default is 5_000_000).
config :loopctl, :full_content_byte_budget, 100_000

# Graph-traversal node cap — small in tests so the `truncated` cap behavior can
# be exercised with ~11 nodes instead of 100+ (production default is 100).
config :loopctl, :max_graph_nodes, 10

# Distant-pairs candidate cap — small in tests so the O(n²) self-join sampling
# cap can be exercised with ~26 articles instead of 1000+ (production default is
# 1000). Keep comfortably above the article count of any non-truncation test.
config :loopctl, :max_pair_candidates, 25

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
# - concurrency caps default to prod values (global 2, per-tenant 1) — the cap test
#   asserts against those.
config :loopctl, :export_chunk_size, 3
config :loopctl, :export_max_links_per_article, 5

# WebAuthn relying party — test fixtures expect localhost
config :loopctl, :webauthn,
  rp_id: "localhost",
  origin: "http://localhost:4002",
  user_verification: "preferred"

# DI: Use mock secrets adapter in tests
config :loopctl, :secrets_adapter, Loopctl.MockSecrets

# DI (US-27.3): suggested-links executor. The default stub in
# DataCase.stub_all_defaults/0 delegates to the real Loopctl.Knowledge, so
# existing tests exercise the genuine query; the DB-error-surfacing test
# overrides it with Mox.expect/3 to inject a deterministic Postgrex.Error.
config :loopctl, :knowledge_suggest_links, Loopctl.MockSuggestLinks

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

# DI: Use Req.Test plug for webhook delivery in tests
config :loopctl, :webhook_req_plug, {Req.Test, Loopctl.Webhooks.ReqDelivery}

# DI: Use Req.Test plug for CLI HTTP client in tests
config :loopctl, :cli_req_plug, {Req.Test, Loopctl.CLI.Client}

# Knowledge analytics: record access events synchronously in tests so the
# inserts run inside the test process and share its sandbox connection.
config :loopctl, :analytics_recording_mode, :sync

# RLS: Switch to non-superuser role within transactions so RLS is enforced
# The loopctl_app role must exist and have access to all tables.
config :loopctl, :rls_role, "loopctl_app"
