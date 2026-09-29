defmodule Loopctl.Test.LockGuard do
  @moduledoc """
  Fails an `async: true` test that ends holding a table-level lock on a relation other tests
  use (the #939 follow-up, KB 493d2020).

  Inside the Ecto sandbox a test is one transaction, so DDL — `CREATE TRIGGER`,
  `ALTER TABLE`, `DROP INDEX`, `LOCK TABLE`, `ANALYZE`, `CREATE INDEX` without
  `CONCURRENTLY` — holds its lock until the test ENDS, and every concurrent async test touching
  that table waits out the statement timeout and fails 57014 `query_canceled`: a red that
  never reproduces alone. It shipped three times before this check (the #939 fixes).

  HOW: `start_owners!/2` starts a test's sandbox owners and records their backend PIDs;
  `release/2` is the ONE teardown, run before the owners stop: a SEPARATE non-sandbox
  connection lists the relation locks those PIDs hold in the modes only DDL, maintenance and
  `LOCK TABLE` take. Ordinary reads and writes (ACCESS SHARE, ROW SHARE, ROW EXCLUSIVE) are
  never reported. SHARE UPDATE EXCLUSIVE (`ANALYZE`, `ALTER TABLE ... SET`) is: it blocks
  another test's `VACUUM` or `ANALYZE` of the same table — the per-test
  `vacuum_vector_indexes` VACUUM among them.

  WHY A SEPARATE CONNECTION: it still answers when the test's own transaction is aborted (a
  test that provoked a DB error on purpose), and it cannot see a relation the test CREATED —
  that `pg_class` row is uncommitted — so DDL on a table the test made for itself drops out
  with no exemption list.

  WHAT IT CANNOT SEE, stated so nobody relies on it for these:
  - a lock taken and released BEFORE the test ends (DDL inside a `Repo.transaction` that
    rolls back is a sandbox savepoint, and rolling back frees its locks);
  - a connection the test checks out itself (`Sandbox.checkout/1` in a Task) or one that
    reconnected mid-test under a new backend PID.

  It fails CLOSED: `start/0` refuses to start a guard that cannot read `pg_locks`, and a
  teardown whose own query fails raises rather than passing a test it never checked.
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @conn __MODULE__.Conn

  @ddl_modes ~w(ShareUpdateExclusiveLock ShareLock ShareRowExclusiveLock ExclusiveLock AccessExclusiveLock)

  @locks """
  SELECT n.nspname || '.' || c.relname, l.mode
  FROM pg_locks l
  JOIN pg_class c ON c.oid = l.relation
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE l.pid = ANY($1) AND l.locktype = 'relation' AND l.granted AND l.mode = ANY($2)
  ORDER BY 1, 2
  """

  # AdminRepo's own options for WHERE and HOW to connect, so the guard's pool never drifts.
  @connect_keys ~w(hostname port username password database socket socket_dir ssl ssl_opts
                   parameters connect_timeout timeout types)a

  @doc """
  Starts the non-sandbox pool the check reads through, from test_helper.exs: one connection
  per concurrent test case, so teardowns never queue on it. Idempotent. Raises when the pool
  cannot read `pg_locks`, so a misconfigured guard stops the suite instead of checking nothing.
  `name` and `overrides` exist for LockGuardTest, which starts one that cannot.
  """
  @spec start(atom(), keyword()) :: {:ok, pid()}
  def start(name \\ @conn, overrides \\ []) do
    opts =
      Loopctl.AdminRepo.config()
      |> Keyword.take(@connect_keys)
      |> Keyword.merge(
        name: name,
        pool_size: ExUnit.configuration()[:max_cases] || System.schedulers_online()
      )
      |> Keyword.merge(overrides)

    pid =
      case Postgrex.start_link(opts) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Postgrex.query!(name, @locks, [[], @ddl_modes])
    {:ok, pid}
  end

  @doc """
  Starts a sandbox owner per repo, shared unless `async?`, and returns `{owners, pids}`:
  for an async test the backend PID of every repo's sandbox connection, for a sync test nil.
  If any start or PID read fails, every owner already started is stopped before the error
  propagates, so no checked-out connection outlives a failed setup.
  """
  @spec start_owners!([module()], boolean()) :: {[pid()], [integer()] | nil}
  def start_owners!(repos, async?) do
    {owners, pids} = Enum.reduce(repos, {[], []}, &start_owner(&1, &2, async?))
    {Enum.reverse(owners), if(async?, do: Enum.reverse(pids))}
  end

  defp start_owner(repo, {owners, pids}, async?) do
    owners = [
      unwinding(owners, fn -> Sandbox.start_owner!(repo, shared: not async?) end) | owners
    ]

    if async?,
      do: {owners, [unwinding(owners, fn -> backend_pid(repo) end) | pids]},
      else: {owners, pids}
  end

  @doc """
  THE teardown: the lock check FIRST (when there are PIDs), while the sandbox still holds
  what the test took; then the owners stop, whether or not the check raised.
  """
  @spec release([pid()], [integer()] | nil) :: :ok
  def release(owners, backend_pids) do
    if backend_pids, do: check!(backend_pids)
    :ok
  after
    Enum.each(owners, &Sandbox.stop_owner/1)
  end

  @doc """
  THE one place a test's sandbox is started and its teardown registered: `start_owners!/2`,
  then `release/2` registered with `register` (`ExUnit.Callbacks.on_exit/1`; a test passes
  its own to capture the teardown and run it). Returns the recorded PIDs, nil for a sync
  test. `Loopctl.DataCase.setup_sandbox/1` and `start_owner!/1` both come through here.
  """
  @spec guard_sandbox!([module()], boolean(), (fun() -> term())) :: [integer()] | nil
  def guard_sandbox!(repos, async?, register \\ &ExUnit.Callbacks.on_exit/1) do
    {owners, pids} = start_owners!(repos, async?)
    register.(fn -> release(owners, pids) end)
    pids
  end

  @doc """
  For an async bare `ExUnit.Case` test that owns its sandbox: `guard_sandbox!/3` for one repo.
  Call it from `setup`.
  """
  @spec start_owner!(module()) :: [integer()]
  def start_owner!(repo), do: guard_sandbox!([repo], true)

  @doc false
  def backend_pid(repo) do
    %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()")
    pid
  end

  defp unwinding(owners, fun) do
    fun.()
  catch
    kind, reason ->
      Enum.each(owners, &Sandbox.stop_owner/1)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Raises naming every relation lock in a DDL-only mode `pids` hold on a relation another
  session can see; `:ok` otherwise. Raises too when the guard's OWN query fails: a test the
  guard could not check is not a test that passed it.
  """
  @spec check!([integer()], GenServer.server()) :: :ok
  def check!(pids, conn \\ @conn) do
    case Postgrex.query(conn, @locks, [pids, @ddl_modes]) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: held}} ->
        raise ExUnit.AssertionError, message: message(held)

      {:error, reason} ->
        raise "LockGuard could not read locks through its own connection, so this test " <>
                "was not checked for held DDL locks: " <> Exception.message(reason)
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
