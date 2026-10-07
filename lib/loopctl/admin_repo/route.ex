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

  What production has and the sharing does not: AdminRepo's own connection. An AdminRepo call
  made INSIDE a `Loopctl.Repo.with_tenant/2` body runs in test on the tenant transaction, under
  the RLS role and seeing that transaction's uncommitted rows, where production runs it
  BYPASSRLS on its own connection and sees only committed ones. Measured on 2026-10-07 over the
  delivery, web, runners, context retriever, custody, knowledge, e2e and workers directories:
  one call site does it, `Loopctl.Threads.not_halted/1` reading the tenant row inside
  `in_story_lock/3`, and `tenants` carries no RLS, so it reads the same row either way.
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
  Runs `fun` (a repo's own `transact/2`) counted as a transaction of `repo` in this process.

  Under the route both repos share one connection, and Ecto's `in_transaction?/0` reads the
  connection: `Loopctl.Repo.in_transaction?()` would be true inside an `AdminRepo` transaction
  and the reverse, where production keeps them apart. The guards that say which transaction a
  write must run in (`Loopctl.Webhooks.insert_events_with_delivery/4` refusing a Repo
  transaction, `Loopctl.Delivery.Stages.follow_release/5` requiring the AdminRepo one) would
  then refuse what production allows and allow what it refuses. Both repos call this from
  `transact/2`, and `in_transaction?/0` also asks `own_transaction?/1`. Compiled into the
  repos only under the route.
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
