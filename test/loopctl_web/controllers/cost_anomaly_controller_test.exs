defmodule LoopctlWeb.CostAnomalyControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_tenant_with_anomalies do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        assigned_agent_id: agent.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    anomaly1 =
      fixture(:cost_anomaly, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        anomaly_type: :high_cost,
        story_cost_millicents: 100_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("4.0")
      })

    anomaly2 =
      fixture(:cost_anomaly, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        anomaly_type: :suspiciously_low,
        story_cost_millicents: 100,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("0.004")
      })

    {user_key, _user_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      story1: story1,
      story2: story2,
      anomaly1: anomaly1,
      anomaly2: anomaly2,
      user_key: user_key,
      agent_key: agent_key
    }
  end

  # --- GET /api/v1/cost-anomalies ---

  describe "GET /api/v1/cost-anomalies" do
    test "lists unresolved anomalies", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/cost-anomalies")

      body = json_response(conn, 200)

      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["page"] == 1
    end

    test "includes story title and agent name", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/cost-anomalies")

      body = json_response(conn, 200)

      anomaly_with_agent =
        Enum.find(body["data"], &(&1["story_id"] == ctx.story1.id))

      assert anomaly_with_agent["story_title"] != nil
      assert anomaly_with_agent["agent_name"] == ctx.agent.name
    end

    test "filters by anomaly_type", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/cost-anomalies?anomaly_type=high_cost")

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["anomaly_type"] == "high_cost"
    end

    test "filters by project_id", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/cost-anomalies?project_id=#{ctx.project.id}")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 2
    end

    test "supports pagination", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/cost-anomalies?page=1&page_size=1")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 1
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> get(~p"/api/v1/cost-anomalies")

      assert json_response(conn, 403)
    end

    test "tenant isolation - returns empty for different tenant", %{conn: conn} do
      _ctx = setup_tenant_with_anomalies()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(other_key)
        |> get(~p"/api/v1/cost-anomalies")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end
  end

  # --- PATCH /api/v1/cost-anomalies/:id ---

  describe "PATCH /api/v1/cost-anomalies/:id" do
    test "marks anomaly as resolved", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/cost-anomalies/#{ctx.anomaly1.id}")

      body = json_response(conn, 200)
      assert body["cost_anomaly"]["id"] == ctx.anomaly1.id
      assert body["cost_anomaly"]["resolved"] == true
    end

    test "returns 404 for wrong tenant", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      other_tenant = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other_tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(other_key)
        |> patch(~p"/api/v1/cost-anomalies/#{ctx.anomaly1.id}")

      assert json_response(conn, 404)
    end

    test "returns 404 for non-existent anomaly", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/cost-anomalies/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> patch(~p"/api/v1/cost-anomalies/#{ctx.anomaly1.id}")

      assert json_response(conn, 403)
    end
  end
end
