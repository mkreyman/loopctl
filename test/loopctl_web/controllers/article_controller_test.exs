defmodule LoopctlWeb.ArticleControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/articles" do
    test "creates a tenant-wide article with agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Ecto Multi Pattern",
          "body" => "Use Ecto.Multi for atomic operations.",
          "category" => "pattern",
          "tags" => ["ecto", "transactions"]
        })

      body = json_response(conn, 201)
      assert body["data"]["title"] == "Ecto Multi Pattern"
      assert body["data"]["category"] == "pattern"
      assert body["data"]["tags"] == ["ecto", "transactions"]
      assert body["data"]["status"] == "draft"
      assert is_nil(body["data"]["project_id"])
    end

    test "returns 422 on invalid input", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "",
          "body" => "",
          "category" => ""
        })

      body = json_response(conn, 422)
      assert body["error"]["status"] == 422
      assert body["error"]["details"]["title"] != nil
    end
  end

  describe "POST /api/v1/projects/:project_id/articles" do
    test "creates a project-scoped article", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/projects/#{project.id}/articles", %{
          "title" => "Project Convention",
          "body" => "Follow these conventions for this project.",
          "category" => "convention"
        })

      body = json_response(conn, 201)
      assert body["data"]["title"] == "Project Convention"
      assert body["data"]["project_id"] == project.id
    end
  end

  describe "GET /api/v1/articles" do
    test "lists articles with category and tags filters", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        tags: ["elixir", "ecto"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Decision B",
        category: :decision,
        tags: ["architecture"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern C",
        category: :pattern,
        tags: ["phoenix"]
      })

      # Filter by category
      conn_category =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?category=pattern")

      body = json_response(conn_category, 200)
      assert body["meta"]["total_count"] == 2
      assert length(body["data"]) == 2

      # Filter by tags
      conn_tags =
        build_conn()
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles?tags=elixir")

      body_tags = json_response(conn_tags, 200)
      assert body_tags["meta"]["total_count"] == 1
      assert hd(body_tags["data"])["title"] == "Pattern A"
    end
  end

  describe "GET /api/v1/projects/:project_id/articles" do
    test "lists project-scoped articles only", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "In Project"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project"
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide"
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/articles")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["title"] == "In Project"
    end
  end

  describe "GET /api/v1/articles/:id" do
    test "returns article with preloaded links", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      article_a = fixture(:article, %{tenant_id: tenant.id, title: "Article A"})
      article_b = fixture(:article, %{tenant_id: tenant.id, title: "Article B"})

      fixture(:article_link, %{
        tenant_id: tenant.id,
        source_article_id: article_a.id,
        target_article_id: article_b.id,
        relationship_type: :relates_to
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article_a.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == article_a.id
      assert body["data"]["title"] == "Article A"
      assert length(body["data"]["outgoing_links"]) == 1

      outgoing = hd(body["data"]["outgoing_links"])
      assert outgoing["relationship_type"] == "relates_to"
      assert outgoing["target_article"]["id"] == article_b.id
      assert outgoing["target_article"]["title"] == "Article B"
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/articles/:id" do
    test "agent role gets 403 on update", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{
          "title" => "Updated Title"
        })

      assert json_response(conn, 403)
    end

    test "user role can update article", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{
          "title" => "Updated Title",
          "status" => "published"
        })

      body = json_response(conn, 200)
      assert body["data"]["title"] == "Updated Title"
      assert body["data"]["status"] == "published"
    end
  end

  describe "DELETE /api/v1/articles/:id" do
    test "agent role gets 403 on delete", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn, 403)
    end

    test "archives article (soft delete) with user role", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")

      body = json_response(conn, 200)
      assert body["data"]["status"] == "archived"
    end
  end

  describe "tenant isolation" do
    test "cross-tenant access returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})
      article = fixture(:article, %{tenant_id: tenant_a.id})

      # GET returns 404
      conn_get =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn_get, 404)

      # PATCH returns 404
      conn_patch =
        build_conn()
        |> auth_conn(raw_key)
        |> patch(~p"/api/v1/articles/#{article.id}", %{"title" => "Hijacked"})

      assert json_response(conn_patch, 404)

      # DELETE returns 404
      conn_delete =
        build_conn()
        |> auth_conn(raw_key)
        |> delete(~p"/api/v1/articles/#{article.id}")

      assert json_response(conn_delete, 404)
    end
  end
end
