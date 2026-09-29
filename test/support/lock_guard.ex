defmodule Loopctl.Test.LockGuard do
  @moduledoc """
  Fails an `async: true` test that ends holding a table-level lock on a relation other tests
  use (#939 follow-up, KB 493d2020).

  Inside the Ecto sandbox a test is one transaction, so DDL — `CREATE TRIGGER`,
  `ALTER TABLE`, `DROP INDEX`, `LOCK TABLE`, `CREATE INDEX` without `CONCURRENTLY` — holds its
  SHARE / SHARE ROW EXCLUSIVE / EXCLUSIVE / ACCESS EXCLUSIVE lock until the test ENDS, and
  every concurrent async test touching that table waits out the statement timeout and fails
  57014 `query_canceled`: a red that never reproduces alone. It shipped three times before
  this check (the #939 fixes).

  HOW: the test's sandbox connections' backend PIDs are recorded at setup (`backend_pids/1`).
  At teardown, BEFORE the sandbox rolls back, a SEPARATE non-sandbox connection lists the
  relation locks those PIDs hold in the modes only DDL, maintenance and `LOCK TABLE` take.
  Ordinary reads and writes take ACCESS SHARE, ROW SHARE and ROW EXCLUSIVE and are never
  reported. SHARE UPDATE EXCLUSIVE (`ANALYZE`, `ALTER TABLE ... SET`, `VALIDATE CONSTRAINT`) IS
  reported: it blocks no DML, but it blocks another test's `VACUUM` or `ANALYZE` of the same
  table — the per-test `vacuum_vector_indexes` VACUUM among them — until the test ends.

  WHY A SEPARATE CONNECTION, twice over: it still answers when the test's own transaction is
  aborted (a test that provoked a DB error on purpose), and it cannot see a relation the test
  CREATED — that `pg_class` row is uncommitted — so DDL on a table the test made for itself
  drops out of the join with no exemption list, which is exactly the harmless case.

  It reads LOCKS, not source, so it catches DDL however it is spelled: a literal, a variable,
  a helper, `Ecto.Adapters.SQL.query!/3`, a migration run inline.
  """

  alias Ecto.Adapters.SQL

  require Logger

  @conn __MODULE__.Conn

  @ddl_modes ~w(ShareUpdateExclusiveLock ShareLock ShareRowExclusiveLock ExclusiveLock AccessExclusiveLock)

  @locks """
  SELECT n.nspname || '.' || c.relname, l.mode
  FROM pg_locks l
  JOIN pg_class c ON c.oid = l.relation
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE l.pid = ANY($1) AND l.locktype = 'relation' AND l.granted
    AND l.mode = ANY($2)
  ORDER BY 1, 2
  """

  @doc """
  Starts the non-sandbox connection pool the check reads through, from test_helper.exs. One
  connection per concurrent test case, so teardowns never queue on it. Idempotent: a helper
  evaluated twice in one VM keeps the pool it has.
  """
  @spec start() :: {:ok, pid()}
  def start do
    config = Loopctl.AdminRepo.config()

    case Postgrex.start_link(
           name: @conn,
           hostname: config[:hostname],
           port: config[:port],
           username: config[:username],
           password: config[:password],
           database: config[:database],
           pool_size: ExUnit.configuration()[:max_cases] || System.schedulers_online()
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "The backend PID of each repo's sandbox connection, as the test process sees it."
  @spec backend_pids([module()]) :: [integer()]
  def backend_pids(repos) do
    for repo <- repos do
      %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()")
      pid
    end
  end

  @doc """
  Raises naming every relation lock in a DDL-only mode that `pids` hold on a relation another
  session can see. Call it before the sandbox rolls back.
  """
  @spec check!([integer()]) :: :ok
  def check!(pids), do: judge(Postgrex.query(@conn, @locks, [pids, @ddl_modes]))

  @doc false
  # What a lock query's result means; public so the error branch is testable.
  @spec judge({:ok, Postgrex.Result.t()} | {:error, Exception.t()}) :: :ok
  def judge(result) do
    case result do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: held}} ->
        raise ExUnit.AssertionError, message: message(held)

      # The GUARD could not ask, which says nothing about the test: warn, never fail it.
      {:error, reason} ->
        Logger.warning("LockGuard could not read locks: #{Exception.message(reason)}")
        :ok
    end
  end

  defp message(held) do
    "this async test ends holding table-level locks on shared relations, which block " <>
      "every concurrent async test touching them until 57014 (KB 493d2020): " <>
      inspect(held) <>
      ". Remedies, by what the DDL was for: skipping a trigger — SET LOCAL " <>
      "session_replication_role = replica (needs the superuser test role); provoking a DB " <>
      "error — a transaction-local setting such as SET LOCAL search_path; exercising a " <>
      "table of the test's own — create it inside the test (it is then invisible here); " <>
      "anything else, where the DDL itself is the point — async: false, with the reason."
  end
end
