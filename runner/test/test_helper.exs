Logger.configure(level: :warning)
Application.put_env(:phoenix, :json_library, Jason)

Application.put_env(:loopctl_runner, LoopctlRunner.TestLoopctl.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("t", 64),
  pubsub_server: LoopctlRunner.TestPubSub
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: LoopctlRunner.TestPubSub)
{:ok, _} = LoopctlRunner.TestLoopctl.Endpoint.start_link()

ExUnit.start()
