defmodule Loopctl.Test.LockGuardTest do
  @moduledoc """
  `Loopctl.Test.LockGuard` can fail, fails only on what blocks other tests, and its teardown
  and setup keep their promises.

  `async: false` on purpose, the documented exception to "async: true on every test file"
  (the case's lock guard runs for ASYNC tests only, and these tests take DDL locks
  deliberately). They take them on a probe table COMMITTED for this module, so the guard's
  separate connection can see it, never on a real table another test uses.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Test.LockGuard

  @probe "lock_guard_probe"

  # Once per module and dropped after the LAST test (a per-test drop would run before the
  # sandbox rolls back and wait on the very lock the test took); dropped first if an
  # interrupted run left it behind.
  setup_all do
    Sandbox.unboxed_run(AdminRepo, fn ->
      AdminRepo.query!("DROP TABLE IF EXISTS #{@probe}")
      AdminRepo.query!("CREATE TABLE #{@probe} (id int)")
    end)

    on_exit(fn ->
      Sandbox.unboxed_run(AdminRepo, fn -> AdminRepo.query!("DROP TABLE #{@probe}") end)
    end)
  end

  test "a DDL-mode lock on a table other sessions can see is reported" do
    pids = [LockGuard.backend_pid(AdminRepo)]
    AdminRepo.query!("LOCK TABLE #{@probe} IN SHARE ROW EXCLUSIVE MODE")

    error = assert_raise ExUnit.AssertionError, fn -> LockGuard.check!(pids) end
    assert error.message =~ "public.#{@probe}"
    assert error.message =~ "ShareRowExclusiveLock"
  end

  test "SHARE UPDATE EXCLUSIVE (ANALYZE) is reported too" do
    pids = [LockGuard.backend_pid(AdminRepo)]
    AdminRepo.query!("ANALYZE #{@probe}")

    assert_raise ExUnit.AssertionError, ~r/ShareUpdateExclusiveLock/, fn ->
      LockGuard.check!(pids)
    end
  end

  test "it still reads the locks after the test's own transaction has aborted" do
    pids = [LockGuard.backend_pid(AdminRepo)]
    AdminRepo.query!("LOCK TABLE #{@probe} IN ACCESS EXCLUSIVE MODE")
    assert {:error, _} = AdminRepo.query("SELECT * FROM no_such_table_for_the_guard")

    assert_raise ExUnit.AssertionError, ~r/public\.#{@probe}/, fn -> LockGuard.check!(pids) end
  end

  test "DDL on a table the test created itself is not reported" do
    pids = [LockGuard.backend_pid(AdminRepo)]
    AdminRepo.query!("CREATE TABLE lock_guard_private (id int)")
    AdminRepo.query!("CREATE INDEX ON lock_guard_private (id)")
    AdminRepo.query!("CREATE TEMP TABLE lock_guard_temp (id int)")

    assert LockGuard.check!(pids) == :ok
  end

  test "ordinary reads and writes take no reported lock" do
    pids = [LockGuard.backend_pid(AdminRepo)]
    AdminRepo.query!("INSERT INTO #{@probe} VALUES (1)")
    AdminRepo.query!("SELECT * FROM #{@probe} FOR UPDATE")

    assert LockGuard.check!(pids) == :ok
  end

  test "release/2 checks FIRST and stops the owners even when the check raises" do
    {[owner], pids} = LockGuard.start_owners!([AdminRepo], true)
    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")

    assert_raise ExUnit.AssertionError, fn -> LockGuard.release([owner], pids) end
    refute Process.alive?(owner)
  end

  test "guard_sandbox!/3 registers a teardown that checks the recorded PIDs" do
    pids = LockGuard.guard_sandbox!([AdminRepo], true, capture_teardown())
    teardown = received_teardown()
    assert pids == [LockGuard.backend_pid(AdminRepo)]

    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")
    assert_raise ExUnit.AssertionError, ~r/ExclusiveLock/, teardown
  end

  test "DataCase's async setup records every sandbox connection and fails on a held lock" do
    # In a fresh process, so its sandbox owners are its own and not this sync module's.
    register = capture_teardown()

    {pids, actual} =
      Task.async(fn ->
        %{lock_guard_backend_pids: pids} =
          Loopctl.DataCase.setup_sandbox(%{async: true}, register)

        actual = Enum.map(Loopctl.DataCase.sandbox_repos(), &LockGuard.backend_pid/1)
        AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")
        {pids, actual}
      end)
      |> Task.await()

    teardown = received_teardown()
    assert pids == actual
    assert length(Enum.uniq(pids)) == length(Loopctl.DataCase.sandbox_repos())
    assert_raise ExUnit.AssertionError, ~r/public\.#{@probe}/, teardown
  end

  test "start_owner!/1, for bare-case tests, records the owner's PID for its teardown" do
    assert [pid] = LockGuard.start_owner!(AdminRepo)
    assert is_integer(pid)
  end

  test "a teardown with no recorded PIDs (a sync test's) checks nothing" do
    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")
    assert LockGuard.release([], nil) == :ok
  end

  test "start_owners!/2 stops what it started when a later start fails" do
    before = MapSet.new(Process.list())

    assert_raise MatchError, fn ->
      LockGuard.start_owners!([AdminRepo, NoSuchRepoForTheGuard], true)
    end

    leaked =
      Process.list()
      |> Enum.reject(&MapSet.member?(before, &1))
      |> Enum.filter(&sandbox_owner?/1)

    assert leaked == []
  end

  test "a failure of the guard's own connection fails the check" do
    # A pool that can never connect: its queries return {:error, _} after a short queue wait.
    {:ok, dead} =
      AdminRepo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: "no_such_db_for_guard", pool_size: 1, queue_target: 10)
      |> Keyword.merge(queue_interval: 10)
      |> Postgrex.start_link()

    assert_raise RuntimeError, ~r/could not read locks/, fn -> LockGuard.check!([1], dead) end
  end

  test "a guard that cannot read pg_locks refuses to start" do
    assert_raise DBConnection.ConnectionError, fn ->
      LockGuard.start(:lock_guard_that_cannot_read,
        database: "no_such_db_for_guard",
        pool_size: 1,
        queue_target: 10,
        queue_interval: 10
      )
    end
  end

  test "starting it again keeps the pool it has" do
    assert {:ok, pid} = LockGuard.start()
    assert {:ok, ^pid} = LockGuard.start()
  end

  test "no async bare ExUnit.Case module opens its own sandbox outside LockGuard" do
    async_bare =
      for path <- Path.wildcard("test/**/*_test.exs"),
          source = File.read!(path),
          source =~ ~r/^\s*use ExUnit\.Case,\s*async:\s*true/m,
          into: %{},
          do: {path, source}

    offenders =
      for {path, source} <- async_bare,
          source =~ ~r/\bSandbox\.(start_owner!|checkout)\(/,
          do: path

    assert offenders == [],
           "use Loopctl.Test.LockGuard.start_owner!/1, which carries the teardown lock " <>
             "check, instead of opening a sandbox directly in: #{inspect(offenders)}"

    # The classifier sees every bare-case module that adopted the guard, so the scan is not
    # vacuous.
    adopters =
      for path <- Path.wildcard("test/**/*_test.exs"),
          source = File.read!(path),
          source =~ ~r/^\s*use ExUnit\.Case\b/m,
          source =~ ~r/\bLockGuard\.start_owner!\(/,
          do: path

    assert adopters != []
    assert Enum.reject(adopters, &Map.has_key?(async_bare, &1)) == []
  end

  # A register function that hands the teardown to the test, from whichever process runs the
  # setup; `received_teardown/0` takes it and backstops it with on_exit, so a failing
  # assertion never leaves an owner holding a connection or a probe lock.
  defp capture_teardown do
    test_pid = self()
    fn teardown -> send(test_pid, {:teardown, teardown}) end
  end

  defp received_teardown do
    assert_received {:teardown, teardown}
    on_exit(fn -> quietly(teardown) end)
    teardown
  end

  defp quietly(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # A sandbox owner is the process `Sandbox.start_owner!/2` spawns; its initial call names it.
  defp sandbox_owner?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        match?({Ecto.Adapters.SQL.Sandbox, _fun, _arity}, dict[:"$initial_call"])

      nil ->
        false
    end
  end
end
