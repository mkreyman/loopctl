defmodule Loopctl.Repo do
  @moduledoc """
  Standard Ecto Repo with RLS tenant context support.

  All tenant-scoped queries go through this Repo. The PostgreSQL role
  used by this Repo has RLS enforced, so queries only return rows
  matching the current tenant set via `SET LOCAL app.current_tenant_id`.

  ## Tenant context

  Use `put_tenant_id/1` to store the tenant in the process dictionary,
  then `with_tenant/2` to execute queries inside a transaction with
  the correct `SET LOCAL`:

      Loopctl.Repo.put_tenant_id(tenant_id)
      Loopctl.Repo.with_tenant(tenant_id, fn ->
        Repo.all(Project)
      end)

  ## Superadmin bypass

  For cross-tenant queries (superadmin only), use `Loopctl.AdminRepo`.
  """

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres,
    prepare: :unnamed

  alias Ecto.Adapters.SQL

  @tenant_key {__MODULE__, :tenant_id}

  @doc """
  Stores the tenant_id in the process dictionary for RLS context.
  """
  @spec put_tenant_id(Ecto.UUID.t()) :: :ok
  def put_tenant_id(tenant_id) when is_binary(tenant_id) do
    Process.put(@tenant_key, tenant_id)
    :ok
  end

  @doc """
  Retrieves the current tenant_id from the process dictionary.
  Returns `nil` if no tenant is set.
  """
  @spec get_tenant_id() :: Ecto.UUID.t() | nil
  def get_tenant_id do
    Process.get(@tenant_key)
  end

  @doc """
  Clears the tenant_id from the process dictionary.
  """
  @spec clear_tenant_id() :: :ok
  def clear_tenant_id do
    Process.delete(@tenant_key)
    :ok
  end

  @doc """
  Executes the given function inside a transaction with
  `SET LOCAL app.current_tenant_id` for RLS enforcement.

  This is the primary mechanism for tenant-scoped database access.
  The SET LOCAL is transaction-scoped, so it automatically resets
  when the connection returns to the pool.

  ## Must own its transaction — never nest inside an existing one

  `with_tenant/2` MUST be the transaction owner. Its
  `set_config('app.current_tenant_id', …, true)` and (dev/test) `SET LOCAL ROLE`
  are TRANSACTION-scoped, NOT savepoint-scoped. If called from INSIDE an already
  open `Loopctl.Repo` transaction, the inner `transaction/1` degrades to a
  SAVEPOINT, and those `SET LOCAL` settings then persist PAST the inner
  savepoint — overriding the OUTER transaction's tenant/role context for the
  rest of its lifetime. That is a cross-tenant / role leak, exactly the failure
  the RLS pattern exists to prevent. So this function fails loud (raises) when it
  detects it is nested inside a Repo transaction, rather than silently leaking.
  The check is skipped under the Ecto SQL sandbox, whose per-test transaction
  legitimately makes `in_transaction?/0` return true.

  ## Examples

      Loopctl.Repo.with_tenant(tenant_id, fn ->
        Repo.all(Project)
      end)

      Loopctl.Repo.with_tenant(tenant_id, fn ->
        Repo.insert(%Project{name: "New", tenant_id: tenant_id})
      end)
  """
  @spec with_tenant(Ecto.UUID.t(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_tenant(tenant_id, fun) when is_binary(tenant_id) and is_function(fun, 0) do
    assert_not_nested!()
    put_tenant_id(tenant_id)

    transaction(fn ->
      set_rls_context(tenant_id)
      fun.()
    end)
  end

  # US-33.7 guard: `with_tenant/2` must own its transaction (see @doc above).
  # Fails loud so the follow-on blanket-reroute epic cannot introduce a
  # nested-transaction caller that silently leaks tenant/role context. No current
  # caller nests.
  #
  # IMPORTANT: the guard is INERT under the SQL sandbox (whose per-test
  # transaction makes `in_transaction?/0` true by design), i.e. for the entire
  # test suite. No integration test can catch a nested caller — the decision
  # function is exposed as `assert_not_nested!/2` so at least the RULE is
  # covered in CI (`test/loopctl/repo_nested_transaction_guard_test.exs`);
  # actual nesting must be verified by inspection or in dev/prod.
  defp assert_not_nested! do
    assert_not_nested!(in_transaction?(), sandbox_pool?())
  end

  @doc """
  The pure decision behind the `with_tenant/2` nested-transaction guard.

  Raises when already inside a transaction on a NON-sandbox pool. Public only so
  the sandbox carve-out (which disables the guard for the whole suite) can still
  be exercised by a unit test.
  """
  @spec assert_not_nested!(boolean(), boolean()) :: :ok
  def assert_not_nested!(in_transaction?, sandbox_pool?)

  def assert_not_nested!(true, false) do
    raise "Loopctl.Repo.with_tenant/2 called inside an existing Repo transaction. " <>
            "It must own its transaction: SET LOCAL app.current_tenant_id / ROLE are " <>
            "transaction-scoped and would leak past the inner savepoint into the outer " <>
            "transaction's tenant/role context. Set the RLS context directly in the " <>
            "enclosing transaction instead (see Loopctl.Repo.set_rls_context/1)."
  end

  def assert_not_nested!(_in_transaction?, _sandbox_pool?), do: :ok

  defp sandbox_pool? do
    Keyword.get(config(), :pool) == Ecto.Adapters.SQL.Sandbox
  end

  @doc """
  Sets the PostgreSQL RLS context for the current transaction.

  Sets `app.current_tenant_id` via `set_config/3` and optionally
  switches role to a non-superuser (configured via `:rls_role`)
  so RLS policies are enforced even when the connection user is
  a superuser (as in dev/test).
  """
  @spec set_rls_context(Ecto.UUID.t()) :: :ok
  def set_rls_context(tenant_id) when is_binary(tenant_id) do
    SQL.query!(
      __MODULE__,
      "SELECT set_config('app.current_tenant_id', $1, true)",
      [tenant_id]
    )

    maybe_set_local_role()
    :ok
  end

  # Compile-time RLS role switching.
  # In test/dev, the DB connection is a superuser, so we SET LOCAL ROLE
  # to a non-superuser to enforce RLS policies. In production, the Repo
  # connects as a non-superuser natively, so no role switch is needed.
  #
  # sobelow_skip ["SQL.Query"]
  # The role name is a compile-time constant from config, not user input.
  # Belt-and-suspenders: also ignored in .sobelow-conf.
  case Application.compile_env(:loopctl, :rls_role) do
    nil ->
      defp maybe_set_local_role, do: :ok

    role when is_binary(role) ->
      defp maybe_set_local_role do
        SQL.query!(__MODULE__, "SET LOCAL ROLE #{unquote(role)}", [])
      end
  end
end
