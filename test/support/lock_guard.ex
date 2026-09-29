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
    reconnected mid-test under a new backend PID;
  - `Loopctl.HeavyReadRepo` used directly: the recorded repos are `Loopctl.Repo`,
    `Loopctl.AdminRepo` and `Loopctl.HeavyRead.repo/0`, the facade application code goes
    through (AdminRepo under test).

  A check the guard itself cannot run (its connection failing) warns and passes the test,
  and is counted: `report_skips/0` prints the count after the suite, where `capture_log`
  cannot swallow it.
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  require Logger

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

  @skips {__MODULE__, :skips}

  @doc """
  Starts the non-sandbox pool the check reads through, from test_helper.exs: one connection
  per concurrent test case, so teardowns never queue on it. Idempotent.
  """
  @spec start() :: {:ok, pid()}
  def start do
    unless :persistent_term.get(@skips, nil),
      do: :persistent_term.put(@skips, :counters.new(1, []))

    opts =
      Loopctl.AdminRepo.config()
      |> Keyword.take(@connect_keys)
      |> Keyword.merge(
        name: @conn,
        pool_size: ExUnit.configuration()[:max_cases] || System.schedulers_online()
      )

    case Postgrex.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Starts a sandbox owner per repo and returns `{owners, backend_pids}`: the PIDs of the
  `guarded` repos' sandbox connections, or nil when `guarded` is nil (a sync test). If
  reading a PID fails, the owners it started are stopped before the error propagates, so no
  checked-out connection outlives a failed setup.
  """
  @spec start_owners!([module()], [module()] | nil) :: {[pid()], [integer()] | nil}
  def start_owners!(repos, guarded) do
    owners = Enum.map(repos, &Sandbox.start_owner!(&1, shared: is_nil(guarded)))

    try do
      {owners, if(guarded, do: backend_pids(guarded))}
    rescue
      error ->
        Enum.each(owners, &Sandbox.stop_owner/1)
        reraise error, __STACKTRACE__
    end
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
  @spec guard_sandbox!([module()], [module()] | nil, (fun() -> term())) :: [integer()] | nil
  def guard_sandbox!(repos, guarded, register \\ &ExUnit.Callbacks.on_exit/1) do
    {owners, pids} = start_owners!(repos, guarded)
    register.(fn -> release(owners, pids) end)
    pids
  end

  @doc """
  For an async bare `ExUnit.Case` test that owns its sandbox: `guard_sandbox!/3` for one repo.
  Call it from `setup`.
  """
  @spec start_owner!(module()) :: [integer()]
  def start_owner!(repo), do: guard_sandbox!([repo], [repo])

  @doc "The repos an async test's sandbox is recorded for."
  @spec guarded_repos() :: [module()]
  def guarded_repos, do: Enum.uniq([Loopctl.Repo, Loopctl.AdminRepo, Loopctl.HeavyRead.repo()])

  @doc false
  def backend_pids(repos) do
    for repo <- Enum.uniq(repos) do
      %{rows: [[pid]]} = SQL.query!(repo, "SELECT pg_backend_pid()")
      pid
    end
  end

  @doc """
  Raises naming every relation lock in a DDL-only mode `pids` hold on a relation another
  session can see; `:ok` otherwise. A failure of the guard's OWN query warns, counts a skip
  and returns `:ok`: it says nothing about the test.
  """
  @spec check!([integer()], GenServer.server()) :: :ok
  def check!(pids, conn \\ @conn) do
    case judge(Postgrex.query(conn, @locks, [pids, @ddl_modes])) do
      :ok ->
        :ok

      {:skipped, message} ->
        @skips |> :persistent_term.get() |> :counters.add(1, 1)
        Logger.warning("LockGuard could not read locks: #{message}")
        :ok
    end
  end

  @doc false
  # What a lock query's result means, without side effects: `:ok`, a raise naming the locks,
  # or `{:skipped, message}` when the guard could not ask.
  def judge({:ok, %{rows: []}}), do: :ok
  def judge({:ok, %{rows: held}}), do: raise(ExUnit.AssertionError, message: message(held))
  def judge({:error, reason}), do: {:skipped, Exception.message(reason)}

  @doc false
  # For LockGuardTest only: takes back a skip its deliberate connection failure counted, so the
  # end-of-suite report counts real ones.
  def forget_skip, do: @skips |> :persistent_term.get() |> :counters.sub(1, 1)

  @doc "Prints how many checks the guard could not run. From `ExUnit.after_suite/1`."
  @spec report_skips() :: :ok
  def report_skips do
    case @skips |> :persistent_term.get() |> :counters.get(1) do
      0 ->
        :ok

      skipped ->
        IO.puts(
          :stderr,
          "LockGuard: #{skipped} teardown lock check(s) could not run (the guard's own " <>
            "connection failed); those tests were not checked for held DDL locks."
        )
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
