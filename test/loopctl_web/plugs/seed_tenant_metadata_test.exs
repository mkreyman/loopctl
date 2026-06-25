defmodule LoopctlWeb.Plugs.SeedTenantMetadataTest do
  @moduledoc """
  US-27.4: the plug seeds Logger metadata `tenant_id` from the resolved api key, so
  the (process-scoped) SlowQueryLogger can attribute a request-path slow query to its
  tenant. Reads `current_api_key.tenant_id` (the real source) — NOT a `tenant_id`
  assign, which `SetTenant` does not set.
  """
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.Plugs.SeedTenantMetadata

  setup do
    on_exit(fn -> Logger.metadata(tenant_id: nil) end)
    :ok
  end

  test "seeds tenant_id into Logger metadata from current_api_key", %{conn: conn} do
    tenant_id = Ecto.UUID.generate()
    conn = Plug.Conn.assign(conn, :current_api_key, %{tenant_id: tenant_id})

    SeedTenantMetadata.call(conn, [])

    assert Logger.metadata()[:tenant_id] == tenant_id
  end

  test "seeds nothing for a superadmin key (nil tenant_id)", %{conn: conn} do
    conn = Plug.Conn.assign(conn, :current_api_key, %{tenant_id: nil})

    SeedTenantMetadata.call(conn, [])

    refute Logger.metadata()[:tenant_id]
  end

  test "seeds nothing when no api key is resolved", %{conn: conn} do
    SeedTenantMetadata.call(conn, [])
    refute Logger.metadata()[:tenant_id]
  end
end
