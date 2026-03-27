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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :loopctl, LoopctlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "QO3UeePU6EXaPNWZRMdH5lL+t+XQNelN9GHOJKhFgp8FEtjlvGzWWXoMiQI1EOE3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Oban: inline testing mode (jobs execute synchronously in tests)
config :loopctl, Oban, testing: :inline

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
