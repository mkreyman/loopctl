defmodule LoopctlWeb.AnalyticsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_analytics_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id, title: "Test Epic"})
    agent = fixture(:agent, %{tenant_id: tenant.id, name: "test-agent"})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent.id
      })

    _report =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        model_name: "claude-opus-4",
        input_tokens: 2000,
        output_tokens: 1000,
        cost_millicents: 5000,
        phase: "implementing"
      })

    {orch_key, _orch_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    {user_key, _user_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      story: story,
      orch_key: orch_key,
      agent_key: agent_key,
      user_key: user_key
    }
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/agents
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/agents" do
    test "returns agent metrics for orchestrator role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents")

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 1

      entry = hd(body["data"])
      assert entry["agent_id"] == ctx.agent.id
      assert entry["agent_name"] == "test-agent"
      assert entry["total_cost_millicents"] == 5000
      assert entry["total_input_tokens"] == 2000
      assert entry["total_output_tokens"] == 1000
      assert entry["primary_model"] == "claude-opus-4"
      assert entry["efficiency_rank"] == 1
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_analytics_context()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents?project_id=#{other_project.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "filters by date range", %{conn: conn} do
      ctx = setup_analytics_context()
      tomorrow = Date.add(Date.utc_today(), 1) |> Date.to_iso8601()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents?since=#{tomorrow}")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "supports pagination", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents?page=1&page_size=1")

      body = json_response(conn, 200)
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 1
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/agents")

      assert json_response(conn, 403)
    end

    test "user+ role can access (orchestrator+)", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/analytics/agents")

      assert json_response(conn, 200)
    end

    test "tenant isolation", %{conn: conn} do
      _ctx = setup_analytics_context()

      other_tenant = fixture(:tenant)

      {other_key, _} =
        fixture(:api_key, %{tenant_id: other_tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/agents")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/epics
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/epics" do
    test "returns epic metrics for agent role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/epics")

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 1

      entry = hd(body["data"])
      assert entry["epic_id"] == ctx.epic.id
      assert entry["epic_name"] == "Test Epic"
      assert entry["total_cost_millicents"] == 5000
      assert is_map(entry["model_breakdown"])
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_analytics_context()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/epics?project_id=#{other_project.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "tenant isolation", %{conn: conn} do
      _ctx = setup_analytics_context()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/epics")

      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/projects/:id
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/projects/:id" do
    test "returns project metrics for agent role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/projects/#{ctx.project.id}")

      body = json_response(conn, 200)
      data = body["data"]

      assert data["total_cost_millicents"] == 5000
      assert data["total_input_tokens"] == 2000
      assert data["total_output_tokens"] == 1000
      assert data["agent_count"] == 1
      assert data["story_count"] == 1
      assert is_map(data["cost_by_phase"])
      assert is_map(data["model_breakdown"])
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/projects/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns zeros when project has no token data", %{conn: conn} do
      ctx = setup_analytics_context()
      empty_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/projects/#{empty_project.id}")

      body = json_response(conn, 200)
      data = body["data"]

      assert data["total_cost_millicents"] == 0
      assert data["total_input_tokens"] == 0
      assert data["agent_count"] == 0
      assert data["story_count"] == 0
    end

    test "tenant isolation", %{conn: conn} do
      ctx = setup_analytics_context()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/projects/#{ctx.project.id}")

      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/models
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/models" do
    test "returns model metrics for agent role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/models")

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 1

      entry = hd(body["data"])
      assert entry["model_name"] == "claude-opus-4"
      assert entry["total_cost_millicents"] == 5000
      assert entry["report_count"] == 1
      assert entry["avg_cost_per_report_millicents"] == 5000
      assert is_integer(entry["stories_verified_count"])
      assert is_integer(entry["stories_rejected_count"])
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_analytics_context()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/models?project_id=#{other_project.id}")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns empty for tenant with no data", %{conn: conn} do
      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/models")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "tenant isolation", %{conn: conn} do
      _ctx = setup_analytics_context()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/models")

      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/trends
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/trends" do
    test "returns daily trend for orchestrator role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/trends")

      body = json_response(conn, 200)

      assert length(body["data"]) == 1

      entry = hd(body["data"])
      assert entry["period"] == Date.utc_today() |> Date.to_iso8601()
      assert entry["total_cost_millicents"] == 5000
      assert entry["report_count"] == 1
      assert entry["unique_agents"] == 1
    end

    test "supports weekly granularity", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/trends?granularity=weekly")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
    end

    test "filters by date range", %{conn: conn} do
      ctx = setup_analytics_context()
      tomorrow = Date.add(Date.utc_today(), 1) |> Date.to_iso8601()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/trends?since=#{tomorrow}")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/trends")

      assert json_response(conn, 403)
    end

    test "user+ role can access (orchestrator+)", %{conn: conn} do
      ctx = setup_analytics_context()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/analytics/trends")

      assert json_response(conn, 200)
    end

    test "tenant isolation", %{conn: conn} do
      _ctx = setup_analytics_context()

      other_tenant = fixture(:tenant)

      {other_key, _} =
        fixture(:api_key, %{tenant_id: other_tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/trends")

      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end
end
