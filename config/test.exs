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
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :loopctl, LoopctlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QO3UeePU6EXaPNWZRMdH5lL+t+XQNelN9GHOJKhFgp8FEtjlvGzWWXoMiQI1EOE3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Use simple formatter in test (override JSON default from config.exs)
config :logger, :default_handler,
  formatter: {:logger_formatter, %{template: [:level, ": ", :message, "\n"]}}

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
