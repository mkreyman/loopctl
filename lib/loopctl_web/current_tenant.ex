defmodule LoopctlWeb.CurrentTenant do
  @moduledoc """
  The ONE reading of the request's tenant for a controller: the `current_tenant` assign, not
  the key's `tenant_id`, so an impersonating superadmin acts on the impersonated tenant and one
  without `X-Impersonate-Tenant` (whose `current_tenant` is nil) gets a 400 through the
  `FallbackController` rather than a nil dereference.
  """

  @missing {:error, :bad_request, "Superadmin must use X-Impersonate-Tenant header"}

  @doc "`{:ok, tenant}` for the request's tenant, or the 400 error tuple."
  @spec fetch(Plug.Conn.t()) :: {:ok, map()} | {:error, :bad_request, String.t()}
  def fetch(conn) do
    case conn.assigns[:current_tenant] do
      %{id: _} = tenant -> {:ok, tenant}
      _ -> @missing
    end
  end

  @doc "`{:ok, tenant_id}` for the request's tenant, or the 400 error tuple."
  @spec fetch_id(Plug.Conn.t()) :: {:ok, Ecto.UUID.t()} | {:error, :bad_request, String.t()}
  def fetch_id(conn) do
    case conn.assigns[:current_tenant] do
      %{id: id} when is_binary(id) -> {:ok, id}
      _ -> @missing
    end
  end
end
