defmodule LoopctlWeb.AdminTenantControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Audit

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/admin/tenants" do
    test "lists tenants with stats for superadmin", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant_a = fixture(:tenant, %{name: "Alpha Tenant", status: :active})
      _tenant_b = fixture(:tenant, %{name: "Beta Tenant", status: :suspended})

      # Create resources for tenant_a
      fixture(:project, %{tenant_id: tenant_a.id})
      fixture(:agent, %{tenant_id: tenant_a.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants")

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["meta"]["total_count"] >= 2

      alpha = Enum.find(body["data"], &(&1["name"] == "Alpha Tenant"))
      beta = Enum.find(body["data"], &(&1["name"] == "Beta Tenant"))

      assert alpha["project_count"] == 1
      assert alpha["agent_count"] == 1
      assert alpha["status"] == "active"

      assert beta["project_count"] == 0
      assert beta["agent_count"] == 0
      assert beta["status"] == "suspended"

      # Verify expected fields
      for field <-
            ~w(id name slug email status project_count story_count agent_count api_key_count inserted_at) do
        assert Map.has_key?(alpha, field), "Missing field: #{field}"
      end
    end

    test "filters tenants by status", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      fixture(:tenant, %{name: "Active One", status: :active})
      fixture(:tenant, %{name: "Suspended One", status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?status=suspended")

      body = json_response(conn, 200)

      names = Enum.map(body["data"], & &1["name"])
      assert "Suspended One" in names
      refute "Active One" in names
    end

    test "searches tenants by name or slug", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      fixture(:tenant, %{name: "Findme Corp"})
      fixture(:tenant, %{name: "Other Corp"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?search=findme")

      body = json_response(conn, 200)
      assert body["data"] != []

      assert Enum.all?(body["data"], fn t ->
               String.contains?(String.downcase(t["name"]), "findme")
             end)
    end

    test "paginates results", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      for i <- 1..5 do
        fixture(:tenant, %{name: "Paginated Tenant #{i}"})
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 2
      assert body["meta"]["total_count"] >= 5
    end

    test "non-superadmin gets 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/admin/tenants/:id" do
    test "returns tenant detail with full stats", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Detail Tenant"})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants/#{tenant.id}")

      body = json_response(conn, 200)
      t = body["tenant"]

      assert t["id"] == tenant.id
      assert t["name"] == "Detail Tenant"
      assert t["project_count"] == 1
      assert t["epic_count"] == 1
      assert t["story_count"] == 1
      assert Map.has_key?(t, "settings")
      assert Map.has_key?(t, "updated_at")
    end

    test "returns 404 for non-existent tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/admin/tenants/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/admin/tenants/:id" do
    test "updates tenant with partial settings merge", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{settings: %{"max_webhooks" => 10, "max_projects" => 50}})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{
          "settings" => %{"max_webhooks" => 20}
        })

      body = json_response(conn, 200)
      t = body["tenant"]

      assert t["settings"]["max_webhooks"] == 20
      assert t["settings"]["max_projects"] == 50
    end

    test "updates tenant name", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Old Name"})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{"name" => "New Name"})

      body = json_response(conn, 200)
      assert body["tenant"]["name"] == "New Name"
    end

    test "creates audit log entry on update", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{name: "Audit Target"})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/admin/tenants/#{tenant.id}", %{"name" => "Updated Name"})

      {:ok, result} =
        Audit.list_entries(tenant.id, entity_type: "tenant", action: "tenant_updated")

      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
    end
  end

  describe "POST /api/v1/admin/tenants/:id/suspend" do
    test "suspends an active tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      body = json_response(conn, 200)
      assert body["tenant"]["status"] == "suspended"
    end

    test "suspending already-suspended tenant returns 422", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      body = json_response(conn, 422)
      assert body["error"]["message"] == "Tenant is already suspended"
    end

    test "suspended tenant's API key gets 403", %{conn: conn} do
      {sa_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})
      {tenant_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Suspend
      conn
      |> auth_conn(sa_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      # Tenant's own API call should return 403
      conn2 =
        build_conn()
        |> auth_conn(tenant_key)
        |> get(~p"/api/v1/tenants/me")

      body = json_response(conn2, 403)
      assert body["error"]["message"] == "Access denied"
    end

    test "creates audit log entry for suspension", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/suspend")

      {:ok, result} = Audit.list_entries(tenant.id, action: "tenant_suspended")
      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
      assert entry.entity_type == "tenant"
    end
  end

  describe "POST /api/v1/admin/tenants/:id/activate" do
    test "activates a suspended tenant", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      body = json_response(conn, 200)
      assert body["tenant"]["status"] == "active"
    end

    test "activating already-active tenant returns 422", %{conn: conn} do
      {raw_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :active})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      body = json_response(conn, 422)
      assert body["error"]["message"] == "Tenant is already active"
    end

    test "activated tenant regains API access", %{conn: conn} do
      {sa_key, _} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})
      {tenant_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Activate
      conn
      |> auth_conn(sa_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      # Tenant's own API call should succeed
      conn2 =
        build_conn()
        |> auth_conn(tenant_key)
        |> get(~p"/api/v1/tenants/me")

      assert json_response(conn2, 200)
    end

    test "creates audit log entry for activation", %{conn: conn} do
      {raw_key, api_key} = fixture(:api_key, %{role: :superadmin})

      tenant = fixture(:tenant, %{status: :suspended})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/admin/tenants/#{tenant.id}/activate")

      {:ok, result} = Audit.list_entries(tenant.id, action: "tenant_activated")
      assert length(result.data) == 1
      entry = hd(result.data)
      assert entry.actor_type == "superadmin"
      assert entry.actor_id == api_key.id
    end
  end

  describe "authorization" do
    test "non-superadmin cannot access any admin tenant endpoint", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for {method, path} <- [
            {:get, ~p"/api/v1/admin/tenants"},
            {:get, ~p"/api/v1/admin/tenants/#{tenant.id}"},
            {:patch, ~p"/api/v1/admin/tenants/#{tenant.id}"},
            {:post, ~p"/api/v1/admin/tenants/#{tenant.id}/suspend"},
            {:post, ~p"/api/v1/admin/tenants/#{tenant.id}/activate"}
          ] do
        resp =
          conn
          |> auth_conn(raw_key)
          |> dispatch(LoopctlWeb.Endpoint, method, path)

        assert resp.status == 403, "Expected 403 for #{method} #{path}, got #{resp.status}"
      end
    end
  end
end
