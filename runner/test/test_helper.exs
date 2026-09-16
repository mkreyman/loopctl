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

# Armed before ExUnit.start/1 so every process the suite spawns inherits the marker, and
# swept afterwards: the fixtures detach processes on purpose and a failing test never
# reaches the assertion that would have ended them.
LoopctlRunner.TestStragglers.arm()
ExUnit.after_suite(&LoopctlRunner.TestStragglers.sweep_suite/1)

# The sweep's marker half is only as good as a `ps` that prints another process's
# environment: Linux prints it, macOS refuses it for Apple-signed binaries, which every
# straggler in this suite is. Those tests are excluded by CAPABILITY, probed on this
# machine, never by naming a platform — and an exclude set here is the one option mix test
# merges back from a helper rather than overwriting. The ledger half, which is what covers
# macOS, is tagged with nothing and runs everywhere.
env_ps? = LoopctlRunner.TestStragglers.env_ps?()

# Recorded, not just acted on: a test that wants to know whether those tests ran has to read
# the decision this run was configured with, and a canary that re-probes gets a second
# opinion instead of the fact.
Application.put_env(:loopctl_runner, :env_ps, env_ps?)

if env_ps? == false do
  ExUnit.configure(exclude: [:env_ps])
end

ExUnit.start()
