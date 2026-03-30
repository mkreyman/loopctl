defmodule LoopctlWeb.Plugs.ResolveApiKey do
  @moduledoc """
  Resolves the raw API key to a verified `%ApiKey{}` with preloaded tenant.

  Reads `:raw_api_key` from `conn.assigns`, calls `Auth.verify_api_key/1`,
  and assigns `:current_api_key` and `:current_tenant` on success.

  Skips verification if `:raw_api_key` is nil (no header was provided).
  Rejects suspended tenants with 403.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{raw_api_key: nil}} = conn, _opts), do: conn

  def call(%{assigns: %{raw_api_key: raw_key}} = conn, _opts) when is_binary(raw_key) do
    case Auth.verify_api_key(raw_key) do
      {:ok, api_key} ->
        tenant = api_key.tenant

        # Reject suspended tenants (non-superadmin keys)
        if tenant && tenant.status != :active do
          conn
          |> put_status(:forbidden)
          |> Phoenix.Controller.json(%{
            error: %{status: 403, message: "Access denied"}
          })
          |> halt()
        else
          conn
          |> assign(:current_api_key, api_key)
          |> assign(:current_tenant, tenant)
        end

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: %{status: 401, message: "Invalid API key"}})
        |> halt()
    end
  end

  # No raw_api_key in assigns at all — pass through
  def call(conn, _opts), do: conn
end
