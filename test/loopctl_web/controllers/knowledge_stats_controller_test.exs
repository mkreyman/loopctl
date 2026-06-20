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

      # Dense maps: every category/status present, 0 when none match.
      assert body["by_category"] == %{
               "pattern" => 2,
               "convention" => 2,
               "decision" => 0,
               "finding" => 1,
               "reference" => 0
             }

      assert body["by_status"] == %{
               "draft" => 1,
               "published" => 3,
               "archived" => 1,
               "superseded" => 0
             }
    end

    test "returns dense zero-filled maps when there are no articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/stats")

      body = json_response(conn, 200)
      assert body["total"] == 0
      # Keys are still present (0), so a client never gets nil for a known key.
      assert body["by_category"] == %{
               "pattern" => 0,
               "convention" => 0,
               "decision" => 0,
               "finding" => 0,
               "reference" => 0
             }

      assert body["by_status"] == %{
               "draft" => 0,
               "published" => 0,
               "archived" => 0,
               "superseded" => 0
             }
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
      assert body["by_category"]["pattern"] == 1
      assert body["by_category"]["convention"] == 1
      assert body["by_category"]["finding"] == 0
      assert body["by_status"]["published"] == 1
      assert body["by_status"]["draft"] == 1
    end

    test "a project with no own articles still reports the tenant-wide total", %{conn: conn} do
      tenant = fixture(:tenant)
      empty_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Tenant-wide articles are visible in every project's context, so they are
      # counted even for a project with zero project-specific articles.
      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})
      fixture(:article, %{tenant_id: tenant.id, category: :reference, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{empty_project.id}/knowledge/stats")

      body = json_response(conn, 200)
      assert body["total"] == 2
      assert body["by_category"]["pattern"] == 1
      assert body["by_category"]["reference"] == 1
    end

    test "a malformed (non-UUID) project_id yields tenant-wide counts, not a 500", %{conn: _conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{tenant_id: tenant.id, category: :pattern, status: :published})

      for bad <- ["not-a-uuid", "aaaaaaaaaaaaaaaa"] do
        # The 16-char value would coerce to a bogus-but-valid UUID via
        # Ecto.UUID.cast without the byte_size(36) guard, silently narrowing
        # the count to 0; the guard makes it fall back to tenant-wide instead.
        conn =
          build_conn()
          |> auth_conn(raw_key)
          |> get("/api/v1/projects/#{bad}/knowledge/stats")

        body = json_response(conn, 200)
        assert body["total"] == 1
        assert body["by_category"]["pattern"] == 1
      end
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
      assert body["by_category"]["pattern"] == 1
      # Tenant B's convention article must not leak into tenant A's counts.
      assert body["by_category"]["convention"] == 0
    end
  end
end
