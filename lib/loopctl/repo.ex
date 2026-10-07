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

  @sandbox? Application.compile_env(:loopctl, [__MODULE__, :pool]) == Ecto.Adapters.SQL.Sandbox

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
  The transaction check is skipped under the Ecto SQL sandbox, whose per-test
  transaction makes every call a nested one; there a `with_tenant/2` nested in
  another `with_tenant/2` still raises. Under the sandbox the prior tenant and role
  are also put back when the body returns, since the test's transaction outlives
  this one (see `enter_tenant/2`).

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
    assert_not_nested!(in_transaction?(), @sandbox?)
    put_tenant_id(tenant_id)

    transaction(fn ->
      prior = enter_tenant(tenant_id)
      result = fun.()
      leave_tenant(prior)
      result
    end)
  end

  # Under the SQL sandbox (test) a tenant transaction is a SAVEPOINT inside the test's own, and
  # the tenant setting and `SET LOCAL ROLE` outlive its RELEASE, so whatever ran next on the
  # connection would read as this tenant's RLS role. There the prior values are read in the same
  # statement that sets the tenant, and put back when the body returns; a raise or a failed
  # Multi rolls the savepoint back, which reverts them by itself. Every other pool skips both:
  # its transaction is real and ends with the body. `enter_tenant/2` and `leave_tenant/1` are
  # the one implementation, shared by `with_tenant/2` and `tenant_multi/2`.
  #
  # A tenant already set when one is entered is nesting: production raises on it through
  # `assert_not_nested!/2`, whose transaction check is inert under the sandbox, so the sandbox
  # raises here instead, whatever the enclosing transaction is (another `with_tenant/2`, a
  # `tenant_multi/2`, a `Multi.run`). Without this the restore would hide the nesting.
  if @sandbox? do
    defp enter_tenant(tenant_id) do
      %{rows: [[prior_tenant, prior_role, _]]} =
        SQL.query!(
          __MODULE__,
          "SELECT p.tenant, p.role, set_config('app.current_tenant_id', $1, true) " <>
            "FROM (SELECT current_setting('app.current_tenant_id', true) AS tenant, " <>
            "current_setting('role') AS role) AS p",
          [tenant_id]
        )

      if prior_tenant not in [nil, ""], do: assert_not_nested!(true, false)

      maybe_set_local_role()
      prior_role
    end

    defp leave_tenant(prior_role) do
      SQL.query!(
        __MODULE__,
        "SELECT set_config('app.current_tenant_id', '', true), set_config('role', $1, true)",
        [prior_role]
      )

      :ok
    rescue
      # The body swallowed a failed statement, so the transaction is aborted and will roll
      # back, which reverts both settings; there is nothing to put back.
      error in Postgrex.Error ->
        if error.postgres[:code] == :in_failed_sql_transaction,
          do: :ok,
          else: reraise(error, __STACKTRACE__)
    end

    defp append_restore(multi) do
      Ecto.Multi.run(multi, :rls_restore, fn _repo, %{rls_context: prior} ->
        {:ok, leave_tenant(prior)}
      end)
    end
  else
    defp enter_tenant(tenant_id), do: set_rls_context(tenant_id)
    defp leave_tenant(_prior), do: :ok
    defp append_restore(multi), do: multi
  end

  @doc """
  Wraps `multi` so it runs RLS-scoped to `tenant_id` when passed to `transaction/2`: a first
  step sets the tenant context and, under the SQL sandbox only, a last step puts the prior
  context back (see `with_tenant/2`). For callers that need a Multi's per-step error tuples,
  which a Multi nested inside `with_tenant/2` would lose to the outer rollback. Its step names
  are `:rls_context` and `:rls_restore`.
  """
  @spec tenant_multi(Ecto.UUID.t(), Ecto.Multi.t()) :: Ecto.Multi.t()
  def tenant_multi(tenant_id, %Ecto.Multi{} = multi) when is_binary(tenant_id) do
    # Built where it will run: inside an open transaction its SET LOCAL would leak into it.
    assert_not_nested!(in_transaction?(), @sandbox?)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:rls_context, fn _repo, _changes ->
      {:ok, enter_tenant(tenant_id)}
    end)
    |> Ecto.Multi.append(multi)
    |> append_restore()
  end

  # US-33.7 guard: `with_tenant/2` must own its transaction (see @doc above).
  # Fails loud so the follow-on blanket-reroute epic cannot introduce a
  # nested-transaction caller that silently leaks tenant/role context. No current
  # caller nests.
  #
  # Under the SQL sandbox this guard is inert (the pool is the sandbox), so the suite
  # cannot catch `with_tenant/2` nested in some OTHER transaction. A `with_tenant/2` nested
  # in another tenant transaction is caught there too, by `enter_tenant/2`. The decision
  # function is exposed as `assert_not_nested!/2` so the RULE is covered in CI
  # (`test/loopctl/repo_nested_transaction_guard_test.exs`).
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
            "transaction's tenant/role context. Open the tenant transaction at the top " <>
            "instead: Loopctl.Repo.with_tenant/2, or Loopctl.Repo.tenant_multi/2 for a Multi."
  end

  def assert_not_nested!(_in_transaction?, _sandbox_pool?), do: :ok

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
