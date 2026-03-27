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

# AdminRepo shares the same database but uses a role with BYPASSRLS in production.
# In dev/test, it uses the same credentials as Repo.
config :loopctl, Loopctl.AdminRepo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id]

# Ecto migration defaults — binary UUIDs for all primary and foreign keys
config :loopctl, Loopctl.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id]

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

# Configure Elixir's Logger — structured JSON logging with tenant context.
# Production uses JSON via LoggerJSON; dev/test override with human-readable format.
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: [:request_id, :tenant_id, :remote_ip]}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Override phoenix_ecto's Plug.Exception for CastError (default: 400 -> our: 404)
# An invalid UUID in a URL path means the resource cannot exist, hence 404.
config :phoenix_ecto, :exclude_ecto_exceptions_from_plug, [
  Ecto.CastError,
  Ecto.Query.CastError
]

# Hammer rate limiting (ETS backend)
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

# Oban background jobs
config :loopctl, Oban,
  repo: Loopctl.Repo,
  queues: [default: 10, webhooks: 5, cleanup: 2]

# Cloak Vault — key configured per environment
# Generate a key: :crypto.strong_rand_bytes(32) |> Base.encode64()
config :loopctl, Loopctl.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("tv9k+u3uqigJly2BdAZTVhtkB5uRBNObattywOn5KCE="),
      iv_length: 12
    }
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
