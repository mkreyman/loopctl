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

  # The failing shape below is a RAISE (a sandbox ownership error). The EXIT shape — the one
  # a `rescue`-only guard misses, and the one that would abort the whole supervision-tree
  # start from here — is covered one level down, in `Loopctl.SystemConfigTest`'s
  # "refresh_from/1 guard" block: `refresh/0` is what converts it into the `{:error, reason}`
  # this branch handles. How THIS branch then reduces each shape to a bounded class is
  # covered by the `error_class/1` block below.
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

      # The RAISE shape's bounded class, never the exception's own message — which on a
      # Postgrex/DBConnection struct names the backend host, database and role.
      assert log =~ "error_class=raise:"
      assert_received {^ref, %{error_class: class}}
      assert is_binary(class)
      assert String.starts_with?(class, "raise:")
    end
  end

  # #588 review: `refresh_from/1`'s catch arm logs the exit by BOUNDED class precisely
  # because the raw reason carries the DBConnection checkout tuple — statement and bound
  # parameters (#562). This branch is one frame UP from that guard, and it logs and emits
  # the same reason, so it has to sanitize it too or the guard buys nothing.
  #
  # Driven through the seam rather than `start_link/1`: the test database always answers
  # `AdminRepo.all/1` successfully, so no prime can be made to EXIT — and the exit is the
  # shape whose raw reason actually carries a payload.
  describe "error_class/1" do
    test "an exit reason is reduced to its bounded class, dropping statement and params" do
      reason = {:noproc, {DBConnection, :execute, ["SELECT secret FROM t", ["bound-param"]]}}

      class = CachePrimer.error_class({:exit, reason})

      assert class == "exit:noproc"
      refute class =~ "bound-param"
      refute class =~ "SELECT secret"
    end

    test "the crash-propagation shape reports the exception MODULE, not its message" do
      reason =
        {{%Postgrex.Error{message: "host=db user=secret"}, []}, {DBConnection, :execute, []}}

      class = CachePrimer.error_class({:exit, reason})

      assert class == "exit:Postgrex.Error"
      refute class =~ "secret"
    end

    test "a throw keeps its kind prefix" do
      assert CachePrimer.error_class({:throw, :boom}) == "throw:other"
    end

    test "the rescue arm's bare exception struct is classified as a :raise" do
      assert CachePrimer.error_class(%Postgrex.Error{message: "host=db user=secret"}) ==
               "raise:Postgrex.Error"

      assert CachePrimer.error_class(%RuntimeError{message: "db down"}) == "raise:other"
    end

    test "an unforeseen shape is labelled, never raised — a crash here would abort boot" do
      assert CachePrimer.error_class(:something_else) == "unclassified"
      assert CachePrimer.error_class({:not_a_kind, :whatever}) == "unclassified"
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
