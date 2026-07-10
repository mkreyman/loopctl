defmodule LoopctlWeb.Plugs.CheckCustodyHalt do
  @moduledoc """
  US-26.5.2 AC-4: Returns 503 tenant_halted if the tenant's custody
  operations are halted due to witness divergence.

  Mounted after SetTenant in the :authenticated pipeline.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Tenants

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
      superadmin_memory_oversight?(conn) -> conn
      true -> check_tenant_halt(conn, tenant_id)
    end
  end

  # AC-28.3.4: a human operator must retain memory VISIBILITY (list) and DELETE
  # control during a custody halt — precisely the witness-divergence incident when
  # oversight is most needed. The halt intent (AC-28.3.3) scopes to WRITES ("a
  # custody-halted key cannot write memory"), so freezing the operator's oversight
  # read/delete is counterproductive.
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

  defp check_tenant_halt(conn, tenant_id) do
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
          message: "Custody operations halted due to witness divergence",
          remediation: %{learn_more: "https://loopctl.com/wiki/witness-protocol"}
        }
      })
      |> halt()
    else
      conn
    end
  end
end
