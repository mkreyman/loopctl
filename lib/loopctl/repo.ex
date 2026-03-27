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
    adapter: Ecto.Adapters.Postgres

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
    put_tenant_id(tenant_id)

    transaction(fn ->
      set_rls_context(tenant_id)
      fun.()
    end)
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

    rls_role = Application.get_env(:loopctl, :rls_role)

    if rls_role do
      SQL.query!(
        __MODULE__,
        "SET LOCAL ROLE #{rls_role}",
        []
      )
    end

    :ok
  end
end
