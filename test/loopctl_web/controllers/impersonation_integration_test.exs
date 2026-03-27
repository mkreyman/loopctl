defmodule LoopctlWeb.ImpersonationIntegrationTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp impersonate_conn(conn, tenant_id) do
    put_req_header(conn, "x-impersonate-tenant", tenant_id)
  end

  defp effective_role_conn(conn, role) do
    put_req_header(conn, "x-effective-role", role)
  end

  describe "impersonation sets RLS to target tenant" do
    test "superadmin sees target tenant's projects", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      target_tenant = fixture(:tenant, %{name: "Target Tenant"})
      fixture(:project, %{tenant_id: target_tenant.id, name: "Tenant Project"})

      other_tenant = fixture(:tenant, %{name: "Other Tenant"})
      fixture(:project, %{tenant_id: other_tenant.id, name: "Other Project"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(target_tenant.id)
        |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)

      names = Enum.map(body["data"], & &1["name"])
      assert "Tenant Project" in names
      refute "Other Project" in names
    end
  end

  describe "impersonation mutations logged with superadmin attribution" do
    test "creating a project via impersonation has superadmin audit trail", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      target_tenant = fixture(:tenant, %{name: "Target Tenant"})

      conn
      |> auth_conn(raw_key)
      |> impersonate_conn(target_tenant.id)
      |> effective_role_conn("user")
      |> post(~p"/api/v1/projects", %{
        "name" => "Impersonated Project",
        "slug" => "impersonated-project",
        "repo_url" => "https://github.com/test/impersonated"
      })
      |> json_response(201)

      # Check audit log
      import Ecto.Query

      entry =
        from(a in AuditLog,
          where: a.tenant_id == ^target_tenant.id and a.action == "created",
          order_by: [desc: a.inserted_at],
          limit: 1
        )
        |> AdminRepo.one()

      assert entry != nil
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
      assert entry.actor_label =~ "impersonating"
    end
  end

  describe "non-superadmin impersonation header is ignored" do
    test "user key with impersonation header sees only own tenant data", %{conn: conn} do
      tenant_a = fixture(:tenant, %{name: "Tenant A"})
      tenant_b = fixture(:tenant, %{name: "Tenant B"})
      {key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})
      fixture(:project, %{tenant_id: tenant_a.id, name: "A Project"})
      fixture(:project, %{tenant_id: tenant_b.id, name: "B Project"})

      conn =
        conn
        |> auth_conn(key_a)
        |> impersonate_conn(tenant_b.id)
        |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      names = Enum.map(body["data"], & &1["name"])
      assert "A Project" in names
      refute "B Project" in names
    end
  end

  describe "impersonation with non-existent tenant" do
    test "returns 404", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(Ecto.UUID.generate())
        |> get(~p"/api/v1/projects")

      body = json_response(conn, 404)
      assert body["error"]["message"] == "Tenant not found"
    end
  end

  describe "impersonation with suspended tenant" do
    test "superadmin can impersonate suspended tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      suspended = fixture(:tenant, %{status: :suspended})
      fixture(:project, %{tenant_id: suspended.id, name: "Suspended Project"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(suspended.id)
        |> get(~p"/api/v1/projects")

      body = json_response(conn, 200)
      names = Enum.map(body["data"], & &1["name"])
      assert "Suspended Project" in names
    end
  end

  describe "X-Effective-Role" do
    test "superadmin can access exact_role endpoints with effective role", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      # Story must be in :contracted state for claim to work
      story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

      # Claim requires exact_role: :agent
      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(tenant.id)
        |> effective_role_conn("agent")
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 200)
    end
  end
end
