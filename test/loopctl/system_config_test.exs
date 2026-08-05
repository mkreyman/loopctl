defmodule Loopctl.SystemConfigTest do
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.SystemConfig
  alias Loopctl.SystemConfig.Setting
  alias Loopctl.Workers.ContentIngestionWorker

  setup :verify_on_exit!

  # NOTE ON ASYNC ISOLATION: `:persistent_term` is VM-global (no per-process
  # isolation), so every test here operates on a UNIQUE key — via the
  # `:system_config` fixture (unique key per call) or `unique_key/0`. A test's
  # cache writes therefore can never clobber another async test's entry, and no
  # test mutates a REAL config key that a concurrent worker test reads.
  #
  # There is no tenant-isolation test: `system_configs` is a GLOBAL, non-tenant
  # table (like `tenants`) with no `tenant_id`, accessed only via AdminRepo.

  describe "get_int/2" do
    test "returns the default on a cache miss" do
      assert SystemConfig.get_int(unique_key(), 4242) == 4242
    end

    test "never raises for an unknown key (returns the default)" do
      assert SystemConfig.get_int(unique_key(), 7) == 7
    end
  end

  describe "put/2" do
    test "upserts the row AND updates the persistent_term cache immediately" do
      key = unique_key()

      assert {:ok, %Setting{} = setting} = SystemConfig.put(key, 123)
      assert setting.key == key
      assert setting.value == 123

      # Cache is updated immediately — no refresh needed.
      assert SystemConfig.get_int(key, 0) == 123
      # ...and it lives under the module-scoped persistent_term key.
      assert :persistent_term.get({SystemConfig, key}) == 123
    end

    test "a second put upserts the existing row (unique on key) and updates the cache" do
      key = unique_key()

      assert {:ok, _} = SystemConfig.put(key, 1)
      assert {:ok, updated} = SystemConfig.put(key, 2)
      assert updated.value == 2
      assert SystemConfig.get_int(key, 0) == 2

      # Exactly one row for the key (upsert, not a second insert).
      assert Enum.count(SystemConfig.all(), &(&1.key == key)) == 1
    end
  end

  describe "refresh/0" do
    test "loads seeded DB values into the cache" do
      # Insert a uniquely-keyed row DIRECTLY (the fixture bypasses put/2's cache
      # write), so we prove refresh/0 — not put/2 — is what primes the cache.
      setting = fixture(:system_config, value: 9001)

      # Not in the cache yet.
      assert SystemConfig.get_int(setting.key, -1) == -1

      assert :ok = SystemConfig.refresh()
      assert SystemConfig.get_int(setting.key, -1) == 9001
    end
  end

  # #588 review: the boot primer is a SUPERVISION CHILD, and its documented contract is
  # "a failed prime is loud but NEVER blocks boot". That contract is delivered entirely by
  # refresh/0's guard returning rather than escaping. A `rescue`-only guard delivered it for
  # a RAISE and missed every EXIT — and an exit escaping start_link/1 is converted by the
  # supervisor into a failed child start, so the node never boots at all: the inverse of the
  # contract, on the "DB blip at boot" scenario the contract names.
  #
  # The seam exists because the test database always answers AdminRepo.all/1 successfully;
  # refresh/0 itself is proven wired to refresh_from/1 by the describe block above and by
  # `Loopctl.SystemConfig.CachePrimerTest`.
  describe "refresh_from/1 guard: a DB fault that EXITS, not just one that raises" do
    test "a pool EXIT is caught and reported as an error tuple instead of escaping" do
      # The REAL shape DBConnection/Postgrex exits with — a `{reason, call}` tuple, not a
      # bare atom. A guard tested against `exit(:noproc)` would look correct while missing
      # every production exit.
      reason = {:noproc, {DBConnection, :execute, []}}

      log =
        capture_log(fn ->
          assert SystemConfig.refresh_from(fn -> exit(reason) end) == {:error, {:exit, reason}}
        end)

      assert log =~ "error_class=exit:noproc"
    end

    test "the crash-propagation shape (pool died mid-query) is caught too" do
      # What a pooled connection dying WHILE the query is checked out produces — the shape
      # `Loopctl.ExitClass`/`DbErrorBackstop` were written for (#558).
      reason = {{%Postgrex.Error{message: "boom"}, []}, {DBConnection, :execute, []}}

      log =
        capture_log(fn ->
          assert SystemConfig.refresh_from(fn -> exit(reason) end) == {:error, {:exit, reason}}
        end)

      assert log =~ "error_class=exit:Postgrex.Error"
    end

    test "the exit reason is logged by BOUNDED class only — never the statement or its params" do
      reason = {:noproc, {DBConnection, :execute, ["SELECT secret FROM t", ["bound-param"]]}}

      log = capture_log(fn -> SystemConfig.refresh_from(fn -> exit(reason) end) end)

      assert log =~ "error_class=exit:noproc"
      refute log =~ "bound-param", "bound parameters must never reach the log"
      refute log =~ "SELECT secret", "the failing statement must never reach the log"
    end

    test "a THROW is caught for the same reason (three non-local kinds, not two)" do
      log =
        capture_log(fn ->
          assert SystemConfig.refresh_from(fn -> throw(:boom) end) == {:error, {:throw, :boom}}
        end)

      assert log =~ "error_class=throw:other"
    end

    test "a RAISE is still caught (the pre-existing arm keeps its {:error, exception} shape)" do
      log =
        capture_log(fn ->
          assert {:error, %RuntimeError{}} = SystemConfig.refresh_from(fn -> raise "db down" end)
        end)

      assert log =~ "keeping existing cache"
    end

    test "an already-cached value SURVIVES a failed refresh of any kind" do
      key = unique_key()
      assert {:ok, _} = SystemConfig.put(key, 77)

      capture_log(fn ->
        for fail <- [
              fn -> exit({:noproc, {DBConnection, :execute, []}}) end,
              fn -> throw(:boom) end,
              fn -> raise "db down" end
            ] do
          assert {:error, _} = SystemConfig.refresh_from(fail)
        end
      end)

      assert SystemConfig.get_int(key, -1) == 77
    end
  end

  describe "all/0" do
    test "lists settings including a freshly inserted one" do
      setting = fixture(:system_config, value: 55)
      assert setting.key in Enum.map(SystemConfig.all(), & &1.key)
    end
  end

  describe "call-site wiring" do
    test "ContentIngestionWorker.timeout/1 reads the per-chunk budget from SystemConfig" do
      # A single-chunk job's timeout is exactly one per-chunk budget, so the
      # worker's value must equal what SystemConfig returns for the knob it reads —
      # proving the call site is driven by SystemConfig, not a compile-time
      # constant. We deliberately do NOT mutate the real key here: that would
      # clobber VM-global persistent_term for concurrent async worker tests. The
      # put -> cache -> get override mechanism is proven above with unique keys.
      per_chunk = SystemConfig.get_int("ingestion_per_chunk_timeout_ms", 60_000)
      job = %Oban.Job{args: %{"content" => "tiny", "source_type" => "x"}}

      assert ContentIngestionWorker.timeout(job) == per_chunk
    end
  end

  defp unique_key, do: "test_config_#{System.unique_integer([:positive])}"
end
