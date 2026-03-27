defmodule LoopctlWeb.Plugs.SetTenant do
  @moduledoc """
  Sets the RLS tenant context for the current process.

  Reads `:current_api_key` from `conn.assigns` and calls
  `Repo.put_tenant_id/1` with the key's tenant_id to set
  the RLS context for all subsequent database operations.

  For superadmin keys (tenant_id is nil), no tenant context
  is set, allowing cross-tenant queries via AdminRepo.
  """

  @behaviour Plug

  alias Loopctl.Repo

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{current_api_key: %{tenant_id: nil}}} = conn, _opts) do
    # Superadmin: no tenant context set — queries go through AdminRepo
    conn
  end

  def call(%{assigns: %{current_api_key: %{tenant_id: tenant_id}}} = conn, _opts)
      when is_binary(tenant_id) do
    Repo.put_tenant_id(tenant_id)
    conn
  end

  # No current_api_key in assigns — pass through (RequireAuth will catch this)
  def call(conn, _opts), do: conn
end
