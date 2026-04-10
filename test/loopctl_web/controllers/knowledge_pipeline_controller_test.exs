defmodule LoopctlWeb.KnowledgePipelineControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # --- TC-21.6.3: Pipeline status returns correct metrics ---

  describe "GET /api/v1/knowledge/pipeline" do
    test "returns pipeline status with all sections", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Create some draft articles from review findings
      for i <- 1..3 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Draft #{i}",
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Published one",
        status: :published,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/pipeline")

      body = json_response(conn, 200)

      # Verify structure
      assert is_map(body["data"])
      assert is_integer(body["data"]["pending_extractions"])
      assert is_list(body["data"]["recent_drafts"])
      assert is_number(body["data"]["publish_rate"])
      assert is_map(body["data"]["extraction_errors"])
      assert is_boolean(body["data"]["auto_extract_enabled"])

      # Verify content
      assert body["data"]["pending_extractions"] == 0
      assert length(body["data"]["recent_drafts"]) == 3
      # 1 published / (1 published + 3 drafts) = 0.25
      assert body["data"]["publish_rate"] == 0.25
      assert body["data"]["extraction_errors"]["count"] == 0
      assert body["data"]["extraction_errors"]["recent"] == []
      assert body["data"]["auto_extract_enabled"] == true
    end

    test "recent_drafts includes correct fields", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      source_id = Ecto.UUID.generate()

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Test Draft",
        status: :draft,
        source_type: "review_finding",
        source_id: source_id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/pipeline")

      body = json_response(conn, 200)
      [draft] = body["data"]["recent_drafts"]

      assert is_binary(draft["id"])
      assert draft["title"] == "Test Draft"
      assert draft["source_id"] == source_id
      assert is_binary(draft["inserted_at"])
    end

    test "auto_extract_enabled reflects tenant settings", %{conn: conn} do
      tenant = fixture(:tenant, %{settings: %{"knowledge_auto_extract" => false}})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/pipeline")

      body = json_response(conn, 200)
      assert body["data"]["auto_extract_enabled"] == false
    end

    test "returns empty state for new tenant", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/pipeline")

      body = json_response(conn, 200)
      assert body["data"]["pending_extractions"] == 0
      assert body["data"]["recent_drafts"] == []
      assert body["data"]["publish_rate"] == 0.0
      assert body["data"]["extraction_errors"]["count"] == 0
      assert body["data"]["extraction_errors"]["recent"] == []
      assert body["data"]["auto_extract_enabled"] == true
    end

    # --- AC-21.6.12: Pipeline endpoint enforces tenant scoping via RLS ---

    test "tenant isolation -- tenant A cannot see tenant B data", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :user})

      # Create articles for both tenants
      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "A Draft",
        status: :draft,
        source_type: "review_finding",
        source_id: Ecto.UUID.generate()
      })

      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant_b.id,
          title: "B Draft #{i}",
          status: :draft,
          source_type: "review_finding",
          source_id: Ecto.UUID.generate()
        })
      end

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/pipeline")

      body = json_response(conn, 200)

      # Tenant A should only see its own draft
      assert length(body["data"]["recent_drafts"]) == 1
      assert hd(body["data"]["recent_drafts"])["title"] == "A Draft"
    end

    # --- Role enforcement ---

    test "requires user role (agent gets 403)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/pipeline")

      assert json_response(conn, 403)
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/pipeline")
      assert json_response(conn, 401)
    end
  end
end
