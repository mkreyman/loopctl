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
      {raw_key_1, _api_key_1} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      {raw_key_2, _api_key_2} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(raw_key_1)
      |> post(~p"/api/v1/agents/register", %{
        "name" => "worker-1",
        "agent_type" => "implementer"
      })

      conn2 =
        build_conn()
        |> auth_conn(raw_key_2)
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

    test "rejects non-agent roles (user)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "worker-1",
          "agent_type" => "implementer"
        })

      # exact_role: :agent means only agent keys can register, not user/orchestrator
      assert json_response(conn, 403)
    end

    test "rejects non-agent roles (orchestrator)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "orch-agent",
          "agent_type" => "orchestrator"
        })

      assert json_response(conn, 403)
    end

    test "returns 409 when API key already has an agent", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # First registration should succeed
      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/agents/register", %{
        "name" => "first-agent",
        "agent_type" => "implementer"
      })

      # Second registration with same key should return 409
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/agents/register", %{
          "name" => "second-agent",
          "agent_type" => "implementer"
        })

      assert json_response(conn2, 409)
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

      conn = conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents?agent_type=orchestrator")

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

    test "sorts by sort_by parameter", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator, name: "beta"})
      fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer, name: "alpha"})

      conn =
        conn |> auth_conn(raw_key) |> get(~p"/api/v1/agents?sort_by=agent_type")

      body = json_response(conn, 200)
      types = Enum.map(body["agents"], & &1["agent_type"])
      # implementer < orchestrator alphabetically
      assert types == ["implementer", "orchestrator"]
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
