defmodule LoopctlWeb.IngestionAnomalyControllerTest do
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Knowledge.IngestionHealth

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_tenant_with_anomalies do
    tenant = fixture(:tenant)

    anomaly1 =
      fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "session_log"})

    anomaly2 =
      fixture(:ingestion_anomaly, %{tenant_id: tenant.id, source_type: "newsletter"})

    {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
    {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    %{
      tenant: tenant,
      anomaly1: anomaly1,
      anomaly2: anomaly2,
      user_key: user_key,
      orch_key: orch_key,
      agent_key: agent_key
    }
  end

  # --- GET /api/v1/ingestion-anomalies ---

  describe "GET /api/v1/ingestion-anomalies" do
    test "lists unresolved anomalies for a user", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn = conn |> auth_conn(ctx.user_key) |> get(~p"/api/v1/ingestion-anomalies")
      body = json_response(conn, 200)

      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["page"] == 1
    end

    test "orchestrator (the cost-anomaly read role) can list", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn = conn |> auth_conn(ctx.orch_key) |> get(~p"/api/v1/ingestion-anomalies")
      assert json_response(conn, 200)["meta"]["total_count"] == 2
    end

    test "excludes resolved and archived by default", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      fixture(:ingestion_anomaly, %{
        tenant_id: ctx.tenant.id,
        source_type: "manual",
        resolved: true
      })

      fixture(:ingestion_anomaly, %{
        tenant_id: ctx.tenant.id,
        source_type: "skill",
        archived: true
      })

      conn = conn |> auth_conn(ctx.user_key) |> get(~p"/api/v1/ingestion-anomalies")
      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 2
    end

    test "filters by source_type", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/ingestion-anomalies?source_type=session_log")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["source_type"] == "session_log"
    end

    test "supports pagination", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/ingestion-anomalies?page=1&page_size=1")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["page_size"] == 1
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn = conn |> auth_conn(ctx.agent_key) |> get(~p"/api/v1/ingestion-anomalies")
      assert json_response(conn, 403)
    end

    test "tenant isolation — empty for a different tenant", %{conn: conn} do
      _ctx = setup_tenant_with_anomalies()

      other = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      conn = conn |> auth_conn(other_key) |> get(~p"/api/v1/ingestion-anomalies")
      body = json_response(conn, 200)

      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end
  end

  # --- PATCH /api/v1/ingestion-anomalies/:id ---

  describe "PATCH /api/v1/ingestion-anomalies/:id" do
    test "marks anomaly as resolved (user)", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}")

      body = json_response(conn, 200)
      assert body["ingestion_anomaly"]["id"] == ctx.anomaly1.id
      assert body["ingestion_anomaly"]["resolved"] == true
    end

    test "archives an anomaly with ?archived=true (user)", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}?archived=true")

      body = json_response(conn, 200)
      assert body["ingestion_anomaly"]["id"] == ctx.anomaly1.id
      assert body["ingestion_anomaly"]["archived"] == true
      # Archiving does not resolve — it is a distinct disposition.
      assert body["ingestion_anomaly"]["resolved"] == false
    end

    test "un-archives an anomaly with ?archived=false (user)", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      archived =
        fixture(:ingestion_anomaly, %{
          tenant_id: ctx.tenant.id,
          source_type: "manual",
          archived: true
        })

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{archived.id}?archived=false")

      body = json_response(conn, 200)
      assert body["ingestion_anomaly"]["id"] == archived.id
      assert body["ingestion_anomaly"]["archived"] == false
    end

    test "malformed ?archived value is rejected with 422, not silently resolved", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}?archived=1")

      assert json_response(conn, 422)

      # The anomaly was NOT resolved as a side effect of the malformed request:
      # it still appears in the default (unresolved-only) list.
      {:ok, %{data: data}} = IngestionHealth.list_anomalies(ctx.tenant.id)
      assert ctx.anomaly1.id in Enum.map(data, & &1.id)
    end

    test "resolved=all returns both resolved and unresolved in one call", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      fixture(:ingestion_anomaly, %{
        tenant_id: ctx.tenant.id,
        source_type: "manual",
        resolved: true
      })

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> get(~p"/api/v1/ingestion-anomalies?resolved=all")

      body = json_response(conn, 200)
      # 2 unresolved (from setup) + 1 resolved = 3.
      assert body["meta"]["total_count"] == 3
    end

    test "returns 403 for orchestrator (resolve requires :user)", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.orch_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}")

      assert json_response(conn, 403)
    end

    test "returns 403 for agent role", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.agent_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}")

      assert json_response(conn, 403)
    end

    test "returns 404 for wrong tenant", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      other = fixture(:tenant)
      {other_key, _} = fixture(:api_key, %{tenant_id: other.id, role: :user})

      conn =
        conn
        |> auth_conn(other_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{ctx.anomaly1.id}")

      assert json_response(conn, 404)
    end

    test "returns 404 for non-existent anomaly", %{conn: conn} do
      ctx = setup_tenant_with_anomalies()

      conn =
        conn
        |> auth_conn(ctx.user_key)
        |> patch(~p"/api/v1/ingestion-anomalies/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end
end
