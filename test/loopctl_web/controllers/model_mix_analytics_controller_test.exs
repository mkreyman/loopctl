defmodule LoopctlWeb.ModelMixAnalyticsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_model_mix_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    agent1 = fixture(:agent, %{tenant_id: tenant.id, name: "blender-agent"})
    agent2 = fixture(:agent, %{tenant_id: tenant.id, name: "single-model-agent"})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent1.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :rejected,
        assigned_agent_id: agent2.id
      })

    # agent1: opus for implementing
    _r1 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-opus-4",
        input_tokens: 2000,
        output_tokens: 1000,
        cost_millicents: 6000,
        phase: "implementing"
      })

    # agent1: sonnet for reviewing (blender)
    _r2 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 500,
        output_tokens: 200,
        cost_millicents: 1000,
        phase: "reviewing"
      })

    # agent2: sonnet only
    _r3 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        agent_id: agent2.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500,
        cost_millicents: 2000,
        phase: "implementing"
      })

    {orch_key, _orch_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent1.id})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent1.id})

    %{
      tenant: tenant,
      project: project,
      agent1: agent1,
      agent2: agent2,
      story1: story1,
      story2: story2,
      orch_key: orch_key,
      agent_key: agent_key
    }
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/model-mix
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/model-mix" do
    test "returns model-mix matrix for orchestrator role", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix")

      body = json_response(conn, 200)
      data = body["data"]

      assert Map.has_key?(data, "matrix")
      assert Map.has_key?(data, "comparative")
      assert is_list(data["matrix"])
    end

    test "matrix entries contain required fields", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix")

      body = json_response(conn, 200)
      matrix = body["data"]["matrix"]

      assert matrix != []

      entry = hd(matrix)
      assert Map.has_key?(entry, "model_name")
      assert Map.has_key?(entry, "phase")
      assert Map.has_key?(entry, "total_tokens")
      assert Map.has_key?(entry, "total_cost_millicents")
      assert Map.has_key?(entry, "stories_count")
      assert Map.has_key?(entry, "verified_count")
      assert Map.has_key?(entry, "rejected_count")
      assert Map.has_key?(entry, "verification_rate_pct")
    end

    test "comparative view contains mixed_model and single_model groups", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix")

      body = json_response(conn, 200)
      comparative = body["data"]["comparative"]

      assert Map.has_key?(comparative, "mixed_model")
      assert Map.has_key?(comparative, "single_model")
      assert Map.has_key?(comparative["mixed_model"], "agent_count")
      assert Map.has_key?(comparative["mixed_model"], "avg_verification_rate_pct")
      assert Map.has_key?(comparative["mixed_model"], "avg_cost_per_story_millicents")
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_model_mix_context()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix?project_id=#{other_project.id}")

      body = json_response(conn, 200)
      assert body["data"]["matrix"] == []
    end

    test "filters by agent_id", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix?agent_id=#{ctx.agent2.id}")

      body = json_response(conn, 200)
      matrix = body["data"]["matrix"]

      # Only agent2's reports
      assert length(matrix) == 1
      assert hd(matrix)["model_name"] == "claude-sonnet-4"
    end

    test "filters by date range", %{conn: conn} do
      ctx = setup_model_mix_context()
      tomorrow = Date.add(Date.utc_today(), 1) |> Date.to_iso8601()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/model-mix?since=#{tomorrow}")

      body = json_response(conn, 200)
      assert body["data"]["matrix"] == []
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/model-mix")

      assert json_response(conn, 403)
    end

    test "tenant isolation", %{conn: conn} do
      _ctx = setup_model_mix_context()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/model-mix")

      body = json_response(conn, 200)
      assert body["data"]["matrix"] == []
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/analytics/agents/:id/model-profile
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/analytics/agents/:id/model-profile" do
    test "returns model profile for blender agent", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents/#{ctx.agent1.id}/model-profile")

      body = json_response(conn, 200)
      data = body["data"]

      assert data["agent_id"] == ctx.agent1.id
      assert data["agent_name"] == "blender-agent"
      assert data["model_count"] == 2
      assert data["is_model_blender"] == true
      assert "claude-opus-4" in data["models_used"]
      assert "claude-sonnet-4" in data["models_used"]
    end

    test "returns model profile for single-model agent", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents/#{ctx.agent2.id}/model-profile")

      body = json_response(conn, 200)
      data = body["data"]

      assert data["agent_id"] == ctx.agent2.id
      assert data["model_count"] == 1
      assert data["is_model_blender"] == false
    end

    test "profile includes usage breakdown", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents/#{ctx.agent1.id}/model-profile")

      body = json_response(conn, 200)
      data = body["data"]

      assert is_list(data["usage"])
      assert length(data["usage"]) == 2

      entry = hd(data["usage"])
      assert Map.has_key?(entry, "model_name")
      assert Map.has_key?(entry, "phase")
      assert Map.has_key?(entry, "total_cost_millicents")
      assert Map.has_key?(entry, "verified_count")
      assert Map.has_key?(entry, "rejected_count")
      assert Map.has_key?(entry, "verification_rate_pct")
      assert Map.has_key?(entry, "cost_share_pct")
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_model_mix_context()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(
          ~p"/api/v1/analytics/agents/#{ctx.agent1.id}/model-profile?project_id=#{other_project.id}"
        )

      body = json_response(conn, 200)
      assert body["data"]["usage"] == []
      assert body["data"]["model_count"] == 0
    end

    test "returns 404 for unknown agent", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> get(~p"/api/v1/analytics/agents/#{Ecto.UUID.generate()}/model-profile")

      assert json_response(conn, 404)
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_model_mix_context()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/analytics/agents/#{ctx.agent1.id}/model-profile")

      assert json_response(conn, 403)
    end

    test "tenant isolation - other tenant cannot see agent profile", %{conn: conn} do
      ctx = setup_model_mix_context()
      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/analytics/agents/#{ctx.agent1.id}/model-profile")

      assert json_response(conn, 404)
    end
  end
end
