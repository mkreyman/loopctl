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

    if tenant_id, do: check_tenant_halt(conn, tenant_id), else: conn
  end

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
