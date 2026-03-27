# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :loopctl,
  ecto_repos: [Loopctl.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :loopctl, LoopctlWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LoopctlWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Loopctl.PubSub,
  live_view: [signing_salt: "xpgWTdmT"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Hammer rate limiting (ETS backend)
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

# Oban background jobs
config :loopctl, Oban,
  repo: Loopctl.Repo,
  queues: [default: 10, webhooks: 5]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
