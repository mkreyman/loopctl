defmodule LoopctlWeb.Plugs.RequireRole do
  @moduledoc """
  Enforces role-based access control on API endpoints.

  Checks the `:current_api_key` role against a required minimum role
  using the role hierarchy: superadmin > user > orchestrator > agent.

  ## Options

  - `:role` — minimum required role level. Higher roles can access.
  - `:exact_role` — requires exactly this role (no hierarchy).
    Accepts a single atom or a list of atoms.
    Used for trust model enforcement (e.g., agent-only endpoints).

  ## Usage

  In router pipeline:

      plug RequireRole, role: :user

  In controller:

      plug RequireRole, [exact_role: :agent] when action in [:claim]
      plug RequireRole, [exact_role: [:orchestrator, :superadmin]] when action in [:save]

  ## 403 body (#505)

  Every 403 carries a stable `code` (`insufficient_role`) plus `required_role` /
  `required_roles`, so a client branches on the code and never on the prose
  `message` (`Loopctl.ApiSpec.Schemas.ErrorResponse`).

  It also carries the tenant's TIER capability block, the same one
  `RequireHumanAnchor` emits. Role and tier are two orthogonal gates on the same
  endpoints and this plug is usually mounted FIRST, so an agent-role key on an
  agent-rooted tenant would otherwise be halted here and never see the tier map
  or the agent-native alternative — the pre-#505 dead end, one plug earlier.
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.Auth.Role
  alias Loopctl.Tenants.TierCapabilities

  @impl true
  def init(opts), do: Enum.into(opts, %{})

  @impl true
  def call(%{assigns: %{current_api_key: api_key}} = conn, %{exact_role: exact_roles})
      when is_list(exact_roles) do
    if api_key.role in exact_roles do
      conn
    else
      roles_label = Enum.map_join(exact_roles, " or ", &to_string/1)

      forbid(
        conn,
        "This endpoint requires the #{roles_label} role",
        %{required_roles: Enum.map(exact_roles, &to_string/1)}
      )
    end
  end

  def call(%{assigns: %{current_api_key: api_key}} = conn, %{exact_role: exact_role}) do
    if api_key.role == exact_role do
      conn
    else
      forbid(
        conn,
        "This endpoint requires the #{exact_role} role",
        %{required_roles: [to_string(exact_role)]}
      )
    end
  end

  def call(%{assigns: %{current_api_key: api_key}} = conn, %{role: required_role}) do
    if Role.role_at_least?(api_key.role, required_role) do
      conn
    else
      forbid(
        conn,
        "Insufficient permissions. Required role: #{required_role}",
        %{required_role: to_string(required_role)}
      )
    end
  end

  # FAIL-CLOSED catch-all (#461 item 1). The three clauses above all pattern-match
  # `assigns.current_api_key`, so a route that mounts this plug WITHOUT an
  # authentication plug ahead of it (a future router mistake) would otherwise raise
  # FunctionClauseError — a 500 that leaks a stacktrace and, worse, fails OPEN
  # relative to the intended access decision. Instead we return a clean 401: no
  # authenticated key means the caller is unauthorized, never silently allowed.
  def call(conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{
      error: %{
        status: 401,
        message: "Authentication required"
      }
    })
    |> halt()
  end

  # One shape for every role denial: a stable `code`, the required role(s), and
  # the tenant's tier capability map so the caller can see what its tier DOES
  # include without a second round trip (#505). `compact_for_tenant/1` drops the
  # static per-surface descriptions — those belong on GET /tenants/me, not on
  # every error.
  defp forbid(conn, message, extra) do
    base = Map.merge(extra, %{status: 403, code: "insufficient_role", message: message})

    # No tenant assign at all means a superadmin key (or a pre-tenant pipeline):
    # there is no tier to describe, and stamping the restrictive fallback map
    # would assert a tier the caller is not on.
    body =
      case conn.assigns[:current_tenant] do
        nil -> base
        tenant -> Map.put(base, :capabilities, TierCapabilities.compact_for_tenant(tenant))
      end

    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: body})
    |> halt()
  end
end
