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
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{@probe} IN SHARE ROW EXCLUSIVE MODE")

    error = assert_raise ExUnit.AssertionError, fn -> LockGuard.check!(pids) end
    assert error.message =~ "public.#{@probe}"
    assert error.message =~ "ShareRowExclusiveLock"
  end

  test "SHARE UPDATE EXCLUSIVE (ANALYZE) is reported too" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("ANALYZE #{@probe}")

    assert_raise ExUnit.AssertionError, ~r/ShareUpdateExclusiveLock/, fn ->
      LockGuard.check!(pids)
    end
  end

  test "it still reads the locks after the test's own transaction has aborted" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("LOCK TABLE #{@probe} IN ACCESS EXCLUSIVE MODE")
    assert {:error, _} = AdminRepo.query("SELECT * FROM no_such_table_for_the_guard")

    assert_raise ExUnit.AssertionError, ~r/public\.#{@probe}/, fn -> LockGuard.check!(pids) end
  end

  test "DDL on a table the test created itself is not reported" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("CREATE TABLE lock_guard_private (id int)")
    AdminRepo.query!("CREATE INDEX ON lock_guard_private (id)")
    AdminRepo.query!("CREATE TEMP TABLE lock_guard_temp (id int)")

    assert LockGuard.check!(pids) == :ok
  end

  test "ordinary reads and writes take no reported lock" do
    pids = LockGuard.backend_pids([AdminRepo])
    AdminRepo.query!("INSERT INTO #{@probe} VALUES (1)")
    AdminRepo.query!("SELECT * FROM #{@probe} FOR UPDATE")

    assert LockGuard.check!(pids) == :ok
  end

  test "release/2 checks FIRST and stops the owners even when the check raises" do
    {[owner], pids} = LockGuard.start_owners!([AdminRepo], [AdminRepo])
    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")

    assert_raise ExUnit.AssertionError, fn -> LockGuard.release([owner], pids) end
    refute Process.alive?(owner)
  end

  test "guard_sandbox!/3 registers a teardown that checks the recorded PIDs" do
    test_pid = self()
    register = fn teardown -> send(test_pid, {:teardown, teardown}) end

    pids = LockGuard.guard_sandbox!([AdminRepo], [AdminRepo], register)
    assert [_pid] = pids
    assert_received {:teardown, teardown}

    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")
    assert_raise ExUnit.AssertionError, ~r/ExclusiveLock/, teardown
  end

  test "start_owner!/1, for bare-case tests, records the owner's PID for its teardown" do
    assert [pid] = LockGuard.start_owner!(AdminRepo)
    assert is_integer(pid)
  end

  test "a teardown with no recorded PIDs (a sync test's) checks nothing" do
    AdminRepo.query!("LOCK TABLE #{@probe} IN EXCLUSIVE MODE")
    assert LockGuard.release([], nil) == :ok
  end

  test "start_owners!/2 stops what it started when reading a PID fails" do
    before = MapSet.new(Process.list())

    assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
      LockGuard.start_owners!([AdminRepo], [NoSuchRepoForTheGuard])
    end

    leaked =
      Process.list()
      |> Enum.reject(&MapSet.member?(before, &1))
      |> Enum.filter(&sandbox_owner?/1)

    assert leaked == []
  end

  test "a failure of the guard's own connection warns, counts a skip, and passes" do
    # A pool that can never connect: its queries return {:error, _} after a short queue wait.
    {:ok, dead} =
      AdminRepo.config()
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.merge(database: "no_such_db_for_guard", pool_size: 1, queue_target: 10)
      |> Keyword.merge(queue_interval: 10)
      |> Postgrex.start_link()

    on_exit(fn -> LockGuard.forget_skip() end)

    log =
      ExUnit.CaptureLog.capture_log(fn -> assert LockGuard.check!([1], dead) == :ok end)

    assert log =~ "LockGuard could not read locks"

    assert ExUnit.CaptureIO.capture_io(:stderr, fn -> LockGuard.report_skips() end) =~
             "could not run"
  end

  test "judge/1 reads each result shape without side effects" do
    assert LockGuard.judge({:ok, %Postgrex.Result{rows: []}}) == :ok

    assert {:skipped, "gone"} =
             LockGuard.judge({:error, %DBConnection.ConnectionError{message: "gone"}})
  end

  test "starting it again keeps the pool it has" do
    assert {:ok, pid} = LockGuard.start()
    assert {:ok, ^pid} = LockGuard.start()
  end

  test "an async test's sandbox is recorded for Repo, AdminRepo and the heavy-read facade" do
    assert LockGuard.guarded_repos() ==
             Enum.uniq([Loopctl.Repo, AdminRepo, Loopctl.HeavyRead.repo()])
  end

  test "no async bare ExUnit.Case module opens its own sandbox outside LockGuard" do
    offenders =
      for path <- Path.wildcard("test/**/*_test.exs"),
          source = File.read!(path),
          source =~ ~r/^\s*use ExUnit\.Case,\s*async:\s*true/m,
          source =~ ~r/\bSandbox\.start_owner!\(/,
          do: path

    assert offenders == [],
           "use Loopctl.Test.LockGuard.start_owner!/1, which carries the teardown lock " <>
             "check, instead of Sandbox.start_owner!/2 in: #{inspect(offenders)}"

    # The scan has something to read: the three bare-case modules that do own a sandbox.
    assert length(Path.wildcard("test/loopctl/repo/*_test.exs")) >= 3
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
