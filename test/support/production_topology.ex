defmodule Loopctl.Test.ProductionTopology do
  @moduledoc """
  Puts the calling process back on production's TWO connections: `Loopctl.AdminRepo` on its
  own pool, `Loopctl.Repo` on Repo's.

  In test AdminRepo otherwise runs on Repo's connection (`Loopctl.AdminRepo.Route`), which is
  what lets an async test see one transaction for both repos. It also hides the two things
  only a second connection produces: an AdminRepo transaction committing or rolling back on
  its own while a Repo transaction around it fails, and a process blocking on a lock it holds
  through the other repo. A test whose SUBJECT is one of those calls this, in every process
  that must have the two connections (each Task too: the setting is per process and is not
  inherited).

  THE ONLY SANCTIONED WAY to change which connection AdminRepo uses in a test, and only in
  an `async: false` module whose moduledoc names that cross-connection subject:
  `Loopctl.AdminRepoRouteTest` refuses `put_dynamic_repo` anywhere else in test/. The rows
  such a test uses must be COMMITTED (two connections cannot see each other's sandbox
  transactions) and swept, as `fixture(:committed_tenant)` and its sweep do. Checkouts are
  `sandbox: false`; AdminRepo's own pool is in `:manual` mode (test_helper.exs).
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc "From here on, this process's AdminRepo calls use AdminRepo's own pool."
  @spec admin_repo_on_own_pool!() :: :ok
  def admin_repo_on_own_pool! do
    Loopctl.AdminRepo.put_dynamic_repo(Loopctl.AdminRepo)
    :ok
  end

  @doc """
  `admin_repo_on_own_pool!/0`, then an unsandboxed checkout of each of `repos` in this
  process: one real connection per repo, as in production.
  """
  @spec checkout_unboxed!([module()], keyword()) :: :ok
  def checkout_unboxed!(repos, opts \\ []) do
    admin_repo_on_own_pool!()
    Enum.each(repos, fn repo -> :ok = Sandbox.checkout(repo, [sandbox: false] ++ opts) end)
  end
end
