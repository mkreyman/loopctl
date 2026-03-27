defmodule LoopctlWeb.Plugs.RequireRole do
  @moduledoc """
  Enforces role-based access control on API endpoints.

  Checks the `:current_api_key` role against a required minimum role
  using the role hierarchy: superadmin > user > orchestrator > agent.

  ## Options

  - `:role` — minimum required role level. Higher roles can access.
  - `:exact_role` — requires exactly this role (no hierarchy).
    Used for trust model enforcement (e.g., agent-only endpoints).

  ## Usage

  In router pipeline:

      plug RequireRole, role: :user

  In controller:

      plug RequireRole, [exact_role: :agent] when action in [:claim]
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Auth.Role

  @impl true
  def init(opts), do: Enum.into(opts, %{})

  @impl true
  def call(%{assigns: %{current_api_key: api_key}} = conn, %{exact_role: exact_role}) do
    if api_key.role == exact_role do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{
        error: %{
          status: 403,
          message: "This endpoint requires the #{exact_role} role"
        }
      })
      |> halt()
    end
  end

  def call(%{assigns: %{current_api_key: api_key}} = conn, %{role: required_role}) do
    if Role.role_at_least?(api_key.role, required_role) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{
        error: %{
          status: 403,
          message: "Insufficient permissions. Required role: #{required_role}"
        }
      })
      |> halt()
    end
  end
end
