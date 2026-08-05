defmodule Loopctl.SystemConfig.CachePrimerTest do
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.SystemConfig
  alias Loopctl.SystemConfig.CachePrimer

  setup :verify_on_exit!

  # NOTE ON ASYNC ISOLATION (same rule as system_config_test.exs): `:persistent_term`
  # is VM-global with no per-process isolation, so every test here uses the UNIQUE
  # key minted by the `:system_config` fixture. In particular no test writes the real
  # "embedding_side_table_reads" flag — `Loopctl.ConfigEmbeddingReadPathTest` fails
  # the build on a second writer, and it is a known cross-test flake source.
  #
  # `system_configs` is a GLOBAL, non-tenant table (AdminRepo only), so there is no
  # tenant-isolation test.

  @prime_failed [:loopctl, :system_config, :prime_failed]

  describe "start_link/1" do
    test "primes the cache from the DB and returns :ignore" do
      # Insert DIRECTLY via the fixture (which bypasses put/2's cache write), so
      # this proves the PRIMER — not put/2 — is what populates the cache.
      setting = fixture(:system_config, value: 9001)

      assert SystemConfig.get_int(setting.key, -1) == -1

      assert CachePrimer.start_link([]) == :ignore

      assert SystemConfig.get_int(setting.key, -1) == 9001
    end

    test "a successful prime is silent — no prime_failed telemetry" do
      {handler_id, ref} = attach_prime_failed_handler()

      try do
        assert CachePrimer.start_link([]) == :ignore
      after
        :telemetry.detach(handler_id)
      end

      refute_received {^ref, _meta}
    end
  end

  describe "start_link/1 when the prime FAILS" do
    test "logs at :error, emits prime_failed telemetry, and STILL returns :ignore" do
      {handler_id, ref} = attach_prime_failed_handler()

      log =
        capture_log(fn ->
          try do
            # A bare `spawn` does NOT propagate `$callers`, so this process has no
            # sandbox ownership and AdminRepo raises — a genuine refresh failure,
            # with no Application.put_env and no test-only DI seam.
            assert run_primer_without_db() == :ignore
          after
            :telemetry.detach(handler_id)
          end
        end)

      assert log =~ "boot prime FAILED"
      assert_received {^ref, %{reason: _reason}}
    end
  end

  defp attach_prime_failed_handler do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @prime_failed,
      fn _event, _measurements, meta, _config -> send(test_pid, {ref, meta}) end,
      nil
    )

    {handler_id, ref}
  end

  defp run_primer_without_db do
    parent = self()
    ref = make_ref()

    spawn(fn -> send(parent, {ref, CachePrimer.start_link([])}) end)

    receive do
      {^ref, result} -> result
    after
      5_000 -> flunk("the primer never returned")
    end
  end
end
