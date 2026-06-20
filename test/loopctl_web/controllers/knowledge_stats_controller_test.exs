defmodule LoopctlWeb.KnowledgeStatsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/stats" do
    test "returns total and breakdowns by category and status across all statuses", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant.id, category: :convention, status: :published})
      fixture(:article, %{tenant_id: tenant.id, category: :convention, status: :draft})
      fixture(:article, %{tenant_id: tenant.id, category: :finding, status: :archived})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/stats")

      body = json_response(conn, 200)

      assert body["total"] == 5
      assert body["by_category"] == %{"pattern" => 2, "convention" => 2, "finding" => 1}
      assert body["by_status"] == %{"published" => 3, "draft" => 1, "archived" => 1}
    end

    test "returns zeros when there are no articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/stats")

      body = json_response(conn, 200)
      assert body["total"] == 0
      assert body["by_category"] == %{}
      assert body["by_status"] == %{}
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/stats")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/v1/projects/:project_id/knowledge/stats" do
    test "counts tenant-wide + project-specific, excludes other projects", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Tenant-wide (nil project_id) — counted
      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})
      # Project-specific — counted
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        category: :convention,
        status: :draft
      })

      # Other project — excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        category: :finding,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/knowledge/stats")

      body = json_response(conn, 200)

      assert body["total"] == 2
      assert body["by_category"] == %{"pattern" => 1, "convention" => 1}
      assert body["by_status"] == %{"published" => 1, "draft" => 1}
    end

    test "a malformed (non-UUID) project_id yields tenant-wide counts, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/projects/not-a-uuid/knowledge/stats")

      body = json_response(conn, 200)
      assert body["total"] == 1
      assert body["by_category"] == %{"pattern" => 1}
    end
  end

  describe "tenant isolation" do
    test "tenant A counts do not include tenant B's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{tenant_id: tenant_a.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant_b.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant_b.id, category: :convention, status: :published})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/stats")

      body = json_response(conn, 200)
      assert body["total"] == 1
      assert body["by_category"] == %{"pattern" => 1}
    end
  end
end
