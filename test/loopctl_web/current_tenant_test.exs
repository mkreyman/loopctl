defmodule LoopctlWeb.CurrentTenantTest do
  @moduledoc """
  `LoopctlWeb.CurrentTenant`, the one reading of the request's tenant every tenant-scoped
  controller shares: the `current_tenant` assign (which impersonation rewrites), and the 400 a
  superadmin without `X-Impersonate-Tenant` gets instead of a nil dereference.
  """

  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.CurrentTenant

  @missing {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}

  test "reads the current_tenant assign, as the struct and as its id", %{conn: conn} do
    tenant = fixture(:tenant)
    conn = assign(conn, :current_tenant, tenant)

    assert CurrentTenant.fetch(conn) == {:ok, tenant}
    assert CurrentTenant.fetch_id(conn) == {:ok, tenant.id}
  end

  test "a nil or absent current_tenant is the 400 tuple, never a crash", %{conn: conn} do
    for conn <- [conn, assign(conn, :current_tenant, nil)] do
      assert CurrentTenant.fetch(conn) == @missing
      assert CurrentTenant.fetch_id(conn) == @missing
    end
  end
end
