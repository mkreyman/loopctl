defmodule LoopctlWeb.Plugs.Impersonate do
  @moduledoc """
  Handles superadmin tenant impersonation via the X-Impersonate-Tenant header.

  When a request includes a valid superadmin API key AND an
  `X-Impersonate-Tenant` header with a valid tenant UUID:

  1. Looks up the target tenant (even if suspended)
  2. Sets the RLS context to the impersonated tenant
  3. Updates conn.assigns with impersonation context
  4. Optionally applies X-Effective-Role for role-guarded endpoints

  ## Behavior

  - **Superadmin only**: The header is silently ignored for non-superadmin keys.
  - **Bypasses suspension**: Superadmin can impersonate suspended tenants.
  - **Audit trail**: Sets assigns so downstream audit logging can attribute
    actions to the superadmin with impersonation context.
  - **Effective role**: When X-Effective-Role header is present (user,
    orchestrator, agent), overrides the API key role for RequireRole checks.

  ## Assigns set

  - `:current_tenant` — the impersonated tenant
  - `:impersonating` — `true`
  - `:superadmin_api_key` — the original superadmin API key
  - `:impersonated_tenant_id` — the target tenant ID
  - `:effective_role` — the role to use for role checks (from X-Effective-Role)
  """

  @behaviour Plug

  import Plug.Conn

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant

  @valid_effective_roles ~w(user orchestrator agent)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with %{current_api_key: %{role: :superadmin} = api_key} <- conn.assigns,
         [tenant_id] when tenant_id != "" <- get_req_header(conn, "x-impersonate-tenant"),
         {:ok, tenant} <- lookup_tenant(tenant_id) do
      # Set RLS context for the impersonated tenant
      Repo.put_tenant_id(tenant.id)

      effective_role = resolve_effective_role(conn)

      # Build a virtual API key struct with the effective role for RequireRole checks
      impersonated_api_key =
        if effective_role do
          %{api_key | role: effective_role}
        else
          # Default: superadmin keeps its own role (passes all role checks via hierarchy)
          api_key
        end

      conn
      |> assign(:current_tenant, tenant)
      |> assign(:current_api_key, impersonated_api_key)
      |> assign(:impersonating, true)
      |> assign(:superadmin_api_key, api_key)
      |> assign(:impersonated_tenant_id, tenant.id)
      |> assign(:effective_role, effective_role)
    else
      # Not superadmin, or no header — pass through silently
      %{current_api_key: %{role: _role}} ->
        conn

      # No current_api_key at all — pass through (RequireAuth will catch)
      %{} ->
        conn

      # Header present but tenant not found
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.json(%{error: %{status: 404, message: "Tenant not found"}})
        |> halt()

      # Empty header list (no header present)
      [] ->
        conn
    end
  end

  defp lookup_tenant(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, _} ->
        case AdminRepo.get(Tenant, tenant_id) do
          nil -> {:error, :not_found}
          tenant -> {:ok, tenant}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp resolve_effective_role(conn) do
    case get_req_header(conn, "x-effective-role") do
      [role] when role in @valid_effective_roles ->
        String.to_existing_atom(role)

      _ ->
        nil
    end
  end
end
