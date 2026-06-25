defmodule LoopctlWeb.Plugs.SeedTenantMetadata do
  @moduledoc """
  Seeds `Logger` metadata with `tenant_id` for the request process (US-27.4).

  This lets process-scoped telemetry handlers — notably
  `Loopctl.Telemetry.SlowQueryLogger`, which runs synchronously in the query's
  process — read `Logger.metadata()[:tenant_id]` and attribute a slow query to its
  tenant, matching how `Plug.RequestId` seeds `request_id`.

  The tenant comes from `conn.assigns.current_api_key.tenant_id` (the same source
  `SetTenant`/`LoopctlWeb.DBErrorLogger` use) — NOT a `conn.assigns.tenant_id`
  assign, which `SetTenant` does not set (it puts the tenant on the Repo process
  dict via `Repo.put_tenant_id/1`). A superadmin key (tenant_id nil) seeds nothing.

  Runs after `SetTenant` (so the api key is resolved).
  """

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} when is_binary(tid) -> tid
        _ -> nil
      end

    # ALWAYS write (nil clears) — Bandit reuses a process across keep-alive requests, so
    # a stale tenant_id from a prior request on the same connection must not carry over.
    Logger.metadata(tenant_id: tenant_id)
    conn
  end
end
