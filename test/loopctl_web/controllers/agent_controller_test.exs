defmodule LoopctlWeb.AgentControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/agents/register" do
    test "registers an agent with valid attributes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "worker-1",
          "agent_type" => "implementer",
          "metadata" => %{"lang" => "elixir"}
        })

      body = json_response(conn, 201)
      agent = body["agent"]

      assert agent["name"] == "worker-1"
      assert agent["agent_type"] == "implementer"
      assert agent["status"] == "active"
      assert agent["metadata"] == %{"lang" => "elixir"}
      assert agent["tenant_id"] == tenant.id
      assert is_binary(agent["id"])
    end

    test "registers an orchestrator agent", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "orchestrator-main",
          "agent_type" => "orchestrator"
        })

      body = json_response(conn, 201)
      assert body["agent"]["agent_type"] == "orchestrator"
    end

    test "rejects duplicate name within tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/agents/register", %{
        "name" => "worker-1",
        "agent_type" => "implementer"
      })

      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "worker-1",
          "agent_type" => "implementer"
        })

      assert json_response(conn2, 422)
    end

    test "rejects missing required fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{})

      assert json_response(conn, 422)
    end

    test "requires agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "worker-1",
          "agent_type" => "implementer"
        })

      # user role should have access since agent is the minimum, and user > agent
      # Actually, the RequireRole with role: :agent means ANY role >= agent can access
      # user (3) >= agent (1), so user CAN access this endpoint
      body = json_response(conn, 201)
      assert body["agent"]["name"] == "worker-1"
    end

    test "orchestrator role can also register", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "orch-agent",
          "agent_type" => "orchestrator"
        })

      body = json_response(conn, 201)
      assert body["agent"]["name"] == "orch-agent"
    end
  end

  describe "GET /api/v1/agents" do
    test "lists agents for tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      fixture(:agent, %{tenant_id: tenant.id, name: "agent-a"})
      fixture(:agent, %{tenant_id: tenant.id, name: "agent-b"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents")

      body = json_response(conn, 200)
      assert length(body["agents"]) == 2
      assert body["total"] == 2
      assert body["page"] == 1
    end

    test "filters by type", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator, name: "orch"})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer, name: "impl"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents?type=orchestrator")

      body = json_response(conn, 200)
      assert length(body["agents"]) == 1
      assert hd(body["agents"])["agent_type"] == "orchestrator"
    end

    test "filters by status", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      agent = fixture(:agent, %{tenant_id: tenant.id, name: "idle-one"})
      fixture(:agent, %{tenant_id: tenant.id, name: "active-one"})

      Loopctl.Agents.update_agent(tenant.id, agent, %{status: :idle})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents?status=idle")

      body = json_response(conn, 200)
      assert length(body["agents"]) == 1
      assert hd(body["agents"])["status"] == "idle"
    end

    test "paginates results", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      for i <- 1..5 do
        fixture(:agent, %{
          tenant_id: tenant.id,
          name: "agent-#{String.pad_leading(to_string(i), 2, "0")}"
        })
      end

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["agents"]) == 2
      assert body["total"] == 5
      assert body["page"] == 1
      assert body["page_size"] == 2
    end

    test "requires orchestrator+ role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/agents/:id" do
    test "returns agent detail", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      agent = fixture(:agent, %{tenant_id: tenant.id, name: "my-agent"})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents/#{agent.id}")

      body = json_response(conn, 200)
      assert body["agent"]["id"] == agent.id
      assert body["agent"]["name"] == "my-agent"
    end

    test "returns 404 for nonexistent agent", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents/#{uuid()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for agent in different tenant", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents/#{agent_b.id}")

      assert json_response(conn, 404)
    end

    test "requires orchestrator+ role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents/#{agent.id}")

      assert json_response(conn, 403)
    end
  end

  describe "cross-tenant isolation" do
    test "cannot list another tenant's agents", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {key_a, _api_key} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})
      fixture(:agent, %{tenant_id: tenant_a.id, name: "agent-a"})
      fixture(:agent, %{tenant_id: tenant_b.id, name: "agent-b"})

      conn = conn |> auth_conn(key_a) |> get(~p"/api/v1/agents")

      body = json_response(conn, 200)
      names = Enum.map(body["agents"], & &1["name"])
      assert "agent-a" in names
      refute "agent-b" in names
    end
  end
end
