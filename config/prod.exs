import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :loopctl, LoopctlWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [paths: ["/health"], hosts: ["localhost", "127.0.0.1"]]
  ]

# #461 item 3: mark the signed+encrypted session cookie `secure` (HTTPS-only) in
# prod. Compile-time (the endpoint reads it via `Application.compile_env`), so it
# belongs here, not runtime.exs. Prod terminates TLS and force_ssl above, so the
# cookie is always sent over HTTPS; dev/test leave this unset (false) so the
# LiveView signup handoff still works over plain HTTP.
config :loopctl, :session_secure, true

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
