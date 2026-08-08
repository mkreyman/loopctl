defmodule LoopctlWeb.Plugs.CheckCustodyHalt do
  @moduledoc """
  US-26.5.2 AC-4: Returns 503 tenant_halted when the tenant's custody operations
  are halted AND the request is a custody operation.

  Mounted after SetTenant in the :authenticated pipeline.

  ## Scope

  A halt suspends CUSTODY PROGRESS, not the tenant's whole API. This plug blocks
  only the operations `LoopctlWeb.CustodySurface` classifies as custody surface
  — that module is the authoritative list and carries the reasoning; reads are
  never blocked, on any surface. A halted tenant keeps the read access an
  operator needs to investigate the halt, and a read cannot advance a custody
  chain.

  US-33.2: The halt decision reuses the fully-loaded `current_tenant` struct
  that `ResolveApiKey` already preloaded (`Auth.verify_api_key/1` uses
  `preload: [:tenant]`), instead of issuing a redundant AdminRepo SELECT via
  `Tenants.get_tenant/1`. This drops the authenticated request from 5→4
  AdminRepo queries with zero behavior change. Freshness: `custody_halted_at`
  now reflects its value at api-key resolution time (microseconds earlier, same
  request). This is acceptable — both reads are within the same request, and a
  halt set mid-request is enforced on the very next request. A defensive DB
  fallback (`refetch_and_check/2`) preserves the old behavior when no tenant is
  in assigns (unauthenticated/edge paths).
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant
  alias LoopctlWeb.CustodySurface

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    tenant_id =
      case conn.assigns do
        %{current_api_key: %{tenant_id: tid}} when not is_nil(tid) -> tid
        _ -> nil
      end

    cond do
      is_nil(tenant_id) -> conn
      not CustodySurface.custody_operation?(conn) -> conn
      superadmin_memory_oversight?(conn) -> conn
      true -> check_tenant_halt(conn, tenant_id)
    end
  end

  # AC-28.3.4: a human operator must retain memory VISIBILITY (list) and DELETE
  # control during a custody halt — precisely the incident when oversight is most
  # needed. The halt intent (AC-28.3.3) scopes to WRITES ("a custody-halted key
  # cannot write memory"), so freezing the operator's oversight read/delete is
  # counterproductive.
  #
  # The GET half is now also covered by `CustodySurface` (no read is custody
  # surface), so this bypass is load-bearing for the DELETE — a write, and one
  # that must stay available to an impersonating superadmin.
  #
  # Oversight requires impersonation (the controller returns 422 without
  # X-Impersonate-Tenant), and Impersonate runs BEFORE this plug and rewrites
  # current_api_key.tenant_id to the halted tenant while KEEPING role :superadmin.
  # A standalone superadmin is tenant-less (nil tenant_id) and never reaches the
  # halt check, so `role: :superadmin` here is reachable only via impersonation. We
  # bypass ONLY the GET (list) and DELETE (forget_any) memory endpoints — the two
  # oversight operations — so agent custody writes (and superadmin POST create/recall)
  # stay frozen. A superadmin downgraded via X-Effective-Role has role != :superadmin
  # here, so it does NOT bypass — the halt applies.
  defp superadmin_memory_oversight?(%Plug.Conn{} = conn) do
    match?(%{role: :superadmin}, conn.assigns[:current_api_key]) and
      memory_oversight_path?(conn)
  end

  defp memory_oversight_path?(%Plug.Conn{method: method, path_info: ["api", "v1", "memory" | _]})
       when method in ["GET", "DELETE"],
       do: true

  defp memory_oversight_path?(_conn), do: false

  # US-33.2: Prefer the tenant already loaded by ResolveApiKey/Impersonate and
  # assigned to `current_tenant`. Under impersonation, `current_tenant` is the
  # impersonated tenant (matching `current_api_key.tenant_id`), while
  # `current_api_key.tenant` is the superadmin's original preloaded assoc — so
  # `current_tenant` is the correct source, not `current_api_key.tenant`.
  # Fall back to a DB fetch only when no tenant struct is in assigns.
  defp check_tenant_halt(conn, tenant_id) do
    case conn.assigns[:current_tenant] do
      %Tenant{} = tenant -> maybe_block(conn, tenant)
      _ -> refetch_and_check(conn, tenant_id)
    end
  end

  defp refetch_and_check(conn, tenant_id) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, tenant} -> maybe_block(conn, tenant)
      _ -> conn
    end
  end

  defp maybe_block(conn, tenant) do
    if Tenants.custody_halted?(tenant) do
      conn
      |> put_status(:service_unavailable)
      |> Phoenix.Controller.json(%{
        error: %{
          code: "tenant_halted",
          status: 503,
          message:
            "Custody operations are halted for this tenant and require a break-glass " <>
              "ceremony to clear. Reads and non-custody writes remain available.",
          # State the BOUND in the payload: a client that gets this on one call
          # should not conclude the whole API is down for it.
          scope: "custody_operations_only",
          remediation: %{learn_more: "https://loopctl.com/wiki/witness-protocol"}
        }
      })
      |> halt()
    else
      conn
    end
  end
end
