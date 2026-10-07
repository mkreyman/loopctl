defmodule Loopctl.AdminRepo.Route do
  @moduledoc """
  Where `Loopctl.AdminRepo` sends its queries: decided once, at compile time, from
  `config :loopctl, :admin_repo_route` (`Ecto.Repo`'s `:default_dynamic_repo`).

  Production leaves it unset, so AdminRepo is its own BYPASSRLS pool. `config/test.exs` sets
  it to `Loopctl.Repo`, so in test both repos run on ONE sandbox connection: a row a test
  inserts through either is visible to the other, as it is in production once committed,
  without the test committing it. The value is constant for the whole run and never set per
  test, so nothing reaches it at runtime: no option, no param, no conn field carries a repo.

  `check!/2` is the guard that keeps the sharing out of every build but the sandboxed one:
  routing AdminRepo onto Repo is allowed only while Repo's pool is the SQL sandbox. A shared
  connection in production would run every BYPASSRLS read under whatever RLS role and tenant
  the Repo transaction had set, which is the cross-tenant failure the split repos exist to
  prevent. It raises at compile time, before such a build can start.

  ## What the shared connection cannot show

  Production gives AdminRepo its OWN connection; the route takes it away, in every test that
  does not put it back. Three behaviours exist only with the second connection:

  - **Atomicity.** An AdminRepo transaction opened inside a Repo transaction (an
    `Loopctl.AuditChain.append/2` inside `Loopctl.Repo.with_tenant/2`) commits or rolls back
    on its own in production. On the route it nests in the Repo transaction and shares its
    fate; a raise through it fails the whole outer transaction.
  - **Self-blocking locks.** A process holding a row lock through one repo and writing the
    row through the other waits on itself in production, until `lock_timeout`. On the route
    the one connection already holds the lock and nothing waits.
  - **Visibility and role.** An AdminRepo read inside a tenant transaction runs BYPASSRLS
    and sees only committed rows in production; on the route it runs under the tenant's RLS
    role and sees the transaction's own uncommitted writes. Measured on 2026-10-07 over the
    delivery, web, runners, context retriever, custody, knowledge, e2e and workers
    directories: one call site, `Loopctl.Threads.not_halted/1` reading the tenant row inside
    `in_story_lock/3`, and `tenants` carries no RLS, so it reads the same row either way.

  A test whose SUBJECT is one of these shows it with `Loopctl.Test.ProductionTopology`, which
  puts a process back on AdminRepo's own pool (`Loopctl.AdminRepoTopologyTest` proves the
  first two both ways). Two answers the route would otherwise change are kept as in
  production: `in_transaction?/0` answers per repo (`__using__/1`), and a SAVEPOINT decision
  asks the connection (`connection_in_transaction?/1`).
  """

  @doc """
  Returns the route when it is allowed for a build whose `Loopctl.Repo` pool is `repo_pool`,
  raises `ArgumentError` otherwise. `Loopctl.AdminRepo` calls it at compile time.
  """
  @spec check!(module(), module() | nil) :: module()
  def check!(Loopctl.AdminRepo, _repo_pool), do: Loopctl.AdminRepo
  def check!(Loopctl.Repo, Ecto.Adapters.SQL.Sandbox), do: Loopctl.Repo

  def check!(route, repo_pool) do
    raise ArgumentError,
          "config :loopctl, :admin_repo_route is #{inspect(route)} while Loopctl.Repo's pool " <>
            "is #{inspect(repo_pool)}. Only Loopctl.AdminRepo (production) is allowed, or " <>
            "Loopctl.Repo while Loopctl.Repo's pool is Ecto.Adapters.SQL.Sandbox (test): " <>
            "sharing Repo's connection outside the sandbox would run BYPASSRLS reads under " <>
            "the tenant's RLS role."
  end

  @doc """
  Compiled into a repo that shares the route's connection (`Loopctl.Repo` and
  `Loopctl.AdminRepo`, each only under the route): `transact/2` and `in_transaction?/0` keep
  the per-repo production answer (`counting_transaction/2`). With `telemetry_event:`, the
  repo's Ecto operations and its raw `query/3` and `query!/3` report on that event, where
  Repo's adapter meta would otherwise report them on Repo's (the Postgres adapter has no
  `query_many`).
  """
  defmacro __using__(opts) do
    event = Keyword.get(opts, :telemetry_event)

    quote do
      defoverridable transact: 2, in_transaction?: 0

      @impl true
      def transact(fun_or_multi, opts) do
        unquote(__MODULE__).counting_transaction(__MODULE__, fn -> super(fun_or_multi, opts) end)
      end

      @impl true
      def in_transaction?, do: super() and unquote(__MODULE__).own_transaction?(__MODULE__)

      unquote(
        if event do
          quote do
            @impl true
            def default_options(_operation), do: [telemetry_event: unquote(event)]

            @route_telemetry_event unquote(event)
            @before_compile {unquote(__MODULE__), :__raw_query_telemetry__}
          end
        end
      )
    end
  end

  # The adapter defines `query/3` and `query!/3` in its own `__before_compile__`, after the
  # module body, and they take no default options; this runs after it and overrides them.
  @doc false
  defmacro __raw_query_telemetry__(env) do
    event = Module.get_attribute(env.module, :route_telemetry_event)

    for fun <- [:query, :query!] do
      quote do
        defoverridable [{unquote(fun), 3}]

        def unquote(fun)(sql, params, opts),
          do: super(sql, params, Keyword.put_new(opts, :telemetry_event, unquote(event)))
      end
    end
  end

  @doc """
  Whether the connection this process holds for `repo` is inside a transaction, opened by
  EITHER repo. Every SAVEPOINT decision asks this, never `repo.in_transaction?/0`: under the
  route that answers for the repo's own transactions only, and a statement that needs a
  savepoint to keep its error from aborting the enclosing transaction needs it whichever repo
  opened that transaction. In production the two answers are the same.
  """
  @spec connection_in_transaction?(module()) :: boolean()
  def connection_in_transaction?(repo) do
    %{adapter: adapter} = meta = Ecto.Adapter.lookup_meta(repo.get_dynamic_repo())
    adapter.in_transaction?(meta)
  end

  @doc """
  Runs `fun` (a repo's own `transact/2`) counted as a transaction of `repo` in this process.

  Under the route both repos share one connection, and Ecto's `in_transaction?/0` reads the
  connection: `Loopctl.Repo.in_transaction?()` would be true inside an `AdminRepo` transaction
  and the reverse, where production keeps them apart. The guards that say which transaction a
  write must run in (`Loopctl.Webhooks.insert_events_with_delivery/4` refusing a Repo
  transaction, `Loopctl.Delivery.Stages.follow_release/5` requiring the AdminRepo one) would
  then refuse what production allows and allow what it refuses. `__using__/1` compiles this
  into both repos, under the route only.
  """
  @spec counting_transaction(module(), (-> result)) :: result when result: term()
  def counting_transaction(repo, fun) do
    key = {__MODULE__, repo}
    Process.put(key, Process.get(key, 0) + 1)

    try do
      fun.()
    after
      case Process.get(key) do
        1 -> Process.delete(key)
        depth -> Process.put(key, depth - 1)
      end
    end
  end

  @doc "Whether `repo` itself has a transaction open in this process (see `counting_transaction/2`)."
  @spec own_transaction?(module()) :: boolean()
  def own_transaction?(repo), do: Process.get({__MODULE__, repo}, 0) > 0
end
