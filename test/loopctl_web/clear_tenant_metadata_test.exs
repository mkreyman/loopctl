defmodule LoopctlWeb.ClearTenantMetadataTest do
  @moduledoc """
  US-27.4: the endpoint-level clear_tenant_metadata plug prevents cross-request
  tenant_id leakage on keep-alive Bandit processes. Simulates a prior authenticated
  request setting tenant_id, then verifies the plug clears it before routing.
  """
  use LoopctlWeb.ConnCase, async: true

  setup do
    on_exit(fn -> Logger.metadata(tenant_id: nil) end)
    :ok
  end

  test "clears tenant_id on every request (keep-alive cross-request isolation)", %{conn: conn} do
    # Simulate a prior authenticated request (e.g. POST /stories/:id/report)
    # that ran SeedTenantMetadata and set tenant_id in the process dict.
    prior_tenant_id = Ecto.UUID.generate()
    Logger.metadata(tenant_id: prior_tenant_id)
    assert Logger.metadata()[:tenant_id] == prior_tenant_id

    # The endpoint-level clear_tenant_metadata plug runs before routing.
    # It unconditionally clears tenant_id, so the next request on this
    # Bandit process (even if public/anonymous) starts fresh.
    _ = LoopctlWeb.Endpoint.clear_tenant_metadata(conn, [])

    # Verify tenant_id is now nil (cleared).
    assert Logger.metadata()[:tenant_id] == nil
  end

  test "clears even when no prior tenant_id was set", %{conn: conn} do
    # No prior tenant_id set.
    assert Logger.metadata()[:tenant_id] == nil

    # The plug still runs and succeeds.
    _ = LoopctlWeb.Endpoint.clear_tenant_metadata(conn, [])

    # Still nil (no error).
    assert Logger.metadata()[:tenant_id] == nil
  end

  test "returns the conn unchanged", %{conn: conn} do
    # The plug is transparent to the request flow.
    returned = LoopctlWeb.Endpoint.clear_tenant_metadata(conn, [])
    assert returned == conn
  end
end
