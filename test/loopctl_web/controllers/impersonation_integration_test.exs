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

  describe "impersonation across resource types" do
    setup %{conn: conn} do
      {raw_key, _sa_key} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{name: "Impersonation Target"})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})
      webhook = fixture(:webhook, %{tenant_id: tenant.id})

      base_conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(tenant.id)

      {:ok,
       sa_conn: base_conn,
       tenant: tenant,
       project: project,
       epic: epic,
       story: story,
       agent: agent,
       webhook: webhook}
    end

    test "superadmin can list epics via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/projects/#{ctx.project.id}/epics")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert body["data"] != []
    end

    test "superadmin can get epic detail via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/epics/#{ctx.epic.id}")

      body = json_response(conn, 200)
      assert body["epic"]["id"] == ctx.epic.id
    end

    test "superadmin can list stories via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/epics/#{ctx.epic.id}/stories")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert body["data"] != []
    end

    test "superadmin can get story detail via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/stories/#{ctx.story.id}")

      body = json_response(conn, 200)
      assert body["story"]["id"] == ctx.story.id
    end

    test "superadmin can list agents via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/agents")

      body = json_response(conn, 200)
      assert is_list(body["agents"])
      ids = Enum.map(body["agents"], & &1["id"])
      assert ctx.agent.id in ids
    end

    test "superadmin can get agent detail via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/agents/#{ctx.agent.id}")

      body = json_response(conn, 200)
      assert body["agent"]["id"] == ctx.agent.id
    end

    test "superadmin can list webhooks via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/webhooks")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert ctx.webhook.id in ids
    end

    test "superadmin can save orchestrator state via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> effective_role_conn("orchestrator")
        |> put(~p"/api/v1/orchestrator/state/#{ctx.project.id}", %{
          "state_key" => "main",
          "state_data" => %{"phase" => "testing"}
        })

      body = json_response(conn, 200)
      assert body["state"]["state_key"] == "main"
    end

    test "superadmin can read orchestrator state via impersonation", ctx do
      # First save state
      ctx.sa_conn
      |> effective_role_conn("orchestrator")
      |> put(~p"/api/v1/orchestrator/state/#{ctx.project.id}", %{
        "state_key" => "main",
        "state_data" => %{"phase" => "read-test"}
      })
      |> json_response(200)

      conn =
        ctx.sa_conn
        |> effective_role_conn("orchestrator")
        |> get(~p"/api/v1/orchestrator/state/#{ctx.project.id}")

      body = json_response(conn, 200)
      assert body["state"]["state_data"]["phase"] == "read-test"
    end

    test "superadmin can list dependency graph via impersonation", ctx do
      conn =
        ctx.sa_conn
        |> get(~p"/api/v1/projects/#{ctx.project.id}/dependency_graph")

      body = json_response(conn, 200)
      assert Map.has_key?(body, "graph")
    end
  end

  describe "admin routes are not affected by impersonation" do
    test "impersonation header is ignored on admin routes", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{name: "Targeted Tenant"})

      # Even with impersonation header, admin list-tenants should work normally
      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(tenant.id)
        |> get(~p"/api/v1/admin/tenants")

      body = json_response(conn, 200)
      assert is_list(body["data"])
    end

    test "admin tenant detail works with impersonation header present", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})
      tenant = fixture(:tenant, %{name: "Admin Detail Tenant"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> impersonate_conn(tenant.id)
        |> get(~p"/api/v1/admin/tenants/#{tenant.id}")

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "Admin Detail Tenant"
    end
  end
end
