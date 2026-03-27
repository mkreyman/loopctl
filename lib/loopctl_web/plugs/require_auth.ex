defmodule LoopctlWeb.Plugs.RequireAuth do
  @moduledoc """
  Halts the connection with 401 if `:current_api_key` is not set.

  This is the final guard in the auth pipeline. If no valid API key
  was resolved by upstream plugs, this plug rejects the request.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Map.has_key?(conn.assigns, :current_api_key) do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.json(%{error: %{status: 401, message: "Unauthorized"}})
      |> halt()
    end
  end
end
