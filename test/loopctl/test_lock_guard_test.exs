defmodule Loopctl.Test.LockGuardTest do
  @moduledoc """
  `Loopctl.Test.LockGuard` can fail, and fails only on what blocks other tests.

  `async: false` on purpose: the guard runs at teardown for ASYNC tests only, and these tests
  take DDL locks on a shared table deliberately, which must neither trip their own teardown
  nor block a concurrent async test.
  """

  use Loopctl.DataCase, async: false

  alias Loopctl.AdminRepo
  alias Loopctl.Test.LockGuard

  test "a DDL-mode lock on a shared table is reported" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE tenants IN SHARE ROW EXCLUSIVE MODE")

    error = assert_raise ExUnit.AssertionError, fn -> LockGuard.check!(pids) end
    assert error.message =~ "public.tenants"
    assert error.message =~ "ShareRowExclusiveLock"
  end

  test "it still reads the locks after the test's own transaction has aborted" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE tenants IN ACCESS EXCLUSIVE MODE")
    assert {:error, _} = AdminRepo.query("SELECT * FROM no_such_table_for_the_guard")

    assert_raise ExUnit.AssertionError, ~r/public\.tenants/, fn -> LockGuard.check!(pids) end
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

  test "ordinary reads and writes take no DDL-mode lock" do
    pids = LockGuard.backend_pids([AdminRepo])
    tenant = fixture(:tenant)

    AdminRepo.query!("SELECT * FROM tenants WHERE id = $1 FOR UPDATE", [
      Ecto.UUID.dump!(tenant.id)
    ])

    assert LockGuard.check!(pids) == :ok
  end
end
