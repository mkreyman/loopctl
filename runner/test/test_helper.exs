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

# NO TEST WRITES TO OR DELETES FROM THE OPERATOR'S REAL ~/.claude: every test takes a grant
# directory it made (`TestSupport.config_map/2`). This is the check that sees a breach either
# way — a grant or pending file this BEAM left there, or a live session's grant that went missing
# while the suite ran (`LoopctlRunner.GrantCanary` says why only those). The real directory's
# live grants are read HERE, before any test, because one that is gone at the end cannot be.
real_grant_dir = LoopctlRunner.Config.default_grant_dir()
real_grants_at_start = LoopctlRunner.GrantCanary.snapshot(real_grant_dir)

ExUnit.after_suite(fn _results ->
  breaches =
    case LoopctlRunner.Owner.current() do
      {:ok, suite} ->
        LoopctlRunner.GrantCanary.violations(real_grants_at_start, real_grant_dir, suite)

      {:error, :no_start} ->
        []
    end

  unless breaches == [] do
    IO.puts(:stderr, """

    THE SUITE CHANGED THE OPERATOR'S REAL GRANT DIRECTORY (left: a grant this test run owns;
    removed: a grant whose session was still running):
      #{Enum.map_join(breaches, "\n  ", fn {what, path} -> "#{what} #{path}" end)}
    A session was armed, or a sweep run, with a config whose grant_dir is not the test's own.
    """)

    # ExUnit ignores what an after_suite callback returns, and a raise here is swallowed as a
    # runner crash, so the verdict rides on the exit status.
    System.at_exit(fn _ -> System.halt(3) end)
  end
end)

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

# An owner's start is read one way per kernel (`LoopctlRunner.Owner.clock/0`): each test tagged
# with a clock runs where Owner reads THAT one, decided by the same function Owner decides by.
# One configure call: a second `exclude:` would replace the first, not add to it.
other_clock = if LoopctlRunner.Owner.clock() == :boot, do: :utc, else: :boot
excludes = [clock: other_clock] ++ if(env_ps? == false, do: [:env_ps], else: [])
ExUnit.configure(exclude: excludes)

ExUnit.start()
