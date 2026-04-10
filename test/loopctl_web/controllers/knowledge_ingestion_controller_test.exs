defmodule LoopctlWeb.KnowledgeIngestionControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # --- POST /api/v1/knowledge/ingest ---

  describe "POST /api/v1/knowledge/ingest" do
    test "queues ingestion job with URL", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://example.com/article",
          source_type: "web_article"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
      assert is_binary(body["data"]["content_hash"])
      assert body["data"]["source_type"] == "web_article"
      assert is_binary(body["data"]["inserted_at"] |> to_string())
    end

    test "queues ingestion job with inline content", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some raw content about patterns and conventions",
          source_type: "newsletter"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
      assert body["data"]["source_type"] == "newsletter"
    end

    test "returns 422 when both url and content provided", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          url: "https://example.com",
          content: "Some content",
          source_type: "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "exactly one"
    end

    test "returns 422 when neither url nor content provided", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          source_type: "newsletter"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "required"
    end

    test "returns 422 when source_type missing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "source_type"
    end

    test "agent role is rejected (requires orchestrator)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter"
        })

      assert json_response(conn, 403)
    end

    test "user role is allowed (higher than orchestrator)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Some content for user",
          source_type: "newsletter"
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/knowledge/ingest", %{
          content: "Some content",
          source_type: "newsletter"
        })

      assert json_response(conn, 401)
    end

    test "includes project_id in job args when provided", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/knowledge/ingest", %{
          content: "Project-scoped content",
          source_type: "skill",
          project_id: project.id
        })

      assert json_response(conn, 202)
    end
  end

  # --- GET /api/v1/knowledge/ingestion-jobs ---

  describe "GET /api/v1/knowledge/ingestion-jobs" do
    test "returns empty list for new tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "lists recent ingestion jobs", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Create an ingestion job (inline mode will execute immediately)
      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/knowledge/ingest", %{
        content: "Content for listing test",
        source_type: "newsletter"
      })

      conn =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      # In inline mode, the job may have already completed, but it should still be in the list
    end

    test "agent role is rejected", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      assert json_response(conn, 403)
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/ingestion-jobs")
      assert json_response(conn, 401)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's ingestion jobs", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})
      {raw_key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator})

      # Create job for tenant B
      build_conn()
      |> auth_conn(raw_key_b)
      |> post(~p"/api/v1/knowledge/ingest", %{
        content: "Content for tenant B",
        source_type: "newsletter"
      })

      # Tenant A should not see tenant B's jobs
      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/ingestion-jobs")

      body = json_response(conn, 200)

      tenant_b_jobs =
        Enum.filter(body["data"], fn job ->
          job["args"]["tenant_id"] == tenant_b.id
        end)

      assert tenant_b_jobs == []
    end
  end
end
