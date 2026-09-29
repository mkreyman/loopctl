defmodule Loopctl.Test.LockGuardTest do
  @moduledoc """
  `Loopctl.Test.LockGuard` can fail, fails only on what blocks other tests, and is wired into
  the sandbox teardown of every async test.

  `async: false` on purpose: the guard runs at teardown for ASYNC tests only, and these tests
  take DDL locks deliberately. They take them on a probe table COMMITTED for this module (so
  the guard's separate connection can see it) and dropped afterwards — never on a real table
  another test or process uses.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.DataCase
  alias Loopctl.Test.LockGuard

  # Once per module, committed, and dropped after the LAST test: a per-test drop would run
  # before the sandbox rolls back and wait on the very lock the test took.
  setup_all do
    probe = "lock_guard_probe_#{System.unique_integer([:positive])}"
    Sandbox.unboxed_run(AdminRepo, fn -> AdminRepo.query!("CREATE TABLE #{probe} (id int)") end)

    on_exit(fn ->
      Sandbox.unboxed_run(AdminRepo, fn -> AdminRepo.query!("DROP TABLE #{probe}") end)
    end)

    %{probe: probe}
  end

  test "a DDL-mode lock on a table other sessions can see is reported", %{probe: probe} do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{probe} IN SHARE ROW EXCLUSIVE MODE")

    error = assert_raise ExUnit.AssertionError, fn -> LockGuard.check!(pids) end
    assert error.message =~ "public.#{probe}"
    assert error.message =~ "ShareRowExclusiveLock"
  end

  test "SHARE UPDATE EXCLUSIVE (ANALYZE) is reported too", %{probe: probe} do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{probe} IN SHARE UPDATE EXCLUSIVE MODE")

    assert_raise ExUnit.AssertionError, ~r/ShareUpdateExclusiveLock/, fn ->
      LockGuard.check!(pids)
    end
  end

  test "it still reads the locks after the test's own transaction has aborted", %{probe: probe} do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{probe} IN ACCESS EXCLUSIVE MODE")
    assert {:error, _} = AdminRepo.query("SELECT * FROM no_such_table_for_the_guard")

    assert_raise ExUnit.AssertionError, ~r/public\.#{probe}/, fn -> LockGuard.check!(pids) end
  end

  test "DDL on a table the test created itself is not reported" do
    pids = LockGuard.backend_pids([AdminRepo])

    AdminRepo.query!(
      "CREATE TABLE lock_guard_private_#{System.unique_integer([:positive])} (id int)"
    )

    AdminRepo.query!("CREATE TEMP TABLE lock_guard_temp (id int)")
    AdminRepo.query!("CREATE INDEX ON lock_guard_temp (id)")

    assert LockGuard.check!(pids) == :ok
  end

  test "ordinary reads and writes take no reported lock", %{probe: probe} do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("INSERT INTO #{probe} VALUES (1)")
    AdminRepo.query!("SELECT * FROM #{probe} FOR UPDATE")

    assert LockGuard.check!(pids) == :ok
  end

  test "the teardown checks FIRST and still stops the owners when the check raises",
       %{probe: probe} do
    owner = Sandbox.start_owner!(AdminRepo, shared: false)
    [backend] = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{probe} IN EXCLUSIVE MODE")

    assert_raise ExUnit.AssertionError, fn -> DataCase.release_sandbox([owner], [backend]) end
    refute Process.alive?(owner)
  end

  test "the guard's own connection failing warns and never fails the test" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert LockGuard.judge({:error, %DBConnection.ConnectionError{message: "gone"}}) == :ok
      end)

    assert log =~ "LockGuard could not read locks: gone"
  end

  test "starting it again keeps the pool it has" do
    assert {:ok, pid} = LockGuard.start()
    assert {:ok, ^pid} = LockGuard.start()
  end

  test "a sync test records no backend PIDs, so its teardown checks nothing" do
    assert Process.get(:lock_guard_backend_pids) == nil
  end
end
