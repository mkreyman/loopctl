defmodule LoopctlWeb.AuditContext do
  @moduledoc """
  Helper for extracting audit actor context from a Plug.Conn.

  Checks for impersonation context and returns appropriate actor
  attributes for audit logging. When a superadmin is impersonating
  a tenant, audit entries use `actor_type: "superadmin"` with
  impersonation metadata.

  ## Usage in controllers

      audit_opts = LoopctlWeb.AuditContext.from_conn(conn)
      # Returns keyword list: [actor_id: ..., actor_label: ..., actor_type: ..., metadata: ...]

      Projects.create_project(tenant_id, attrs, audit_opts)
  """

  @doc """
  Extracts audit actor context from the connection.

  Returns a keyword list suitable for passing to context functions as opts.

  When impersonating:
  - `actor_type: "superadmin"`
  - `actor_id: superadmin_api_key.id`
  - `actor_label: "superadmin:impersonating:<tenant_slug>"`
  - `metadata: %{impersonated_by: api_key_id, impersonated_at: iso8601}`

  When not impersonating:
  - `actor_type: "api_key"`
  - `actor_id: api_key.id`
  - `actor_label: "<role>:<key_name>"`
  """
  @spec from_conn(Plug.Conn.t()) :: keyword()
  def from_conn(%Plug.Conn{assigns: assigns}) do
    if Map.get(assigns, :impersonating) do
      sa_key = assigns.superadmin_api_key
      tenant = assigns.current_tenant

      [
        actor_type: "superadmin",
        actor_id: sa_key.id,
        actor_label: "superadmin:impersonating:#{tenant.slug}",
        metadata: %{
          "impersonated_by" => sa_key.id,
          "impersonated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "effective_role" => if(assigns[:effective_role], do: to_string(assigns.effective_role))
        }
      ]
    else
      api_key = assigns.current_api_key

      [
        actor_type: "api_key",
        actor_id: api_key.id,
        actor_label: "#{api_key.role}:#{api_key.name}"
      ]
    end
  end
end
