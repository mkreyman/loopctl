defmodule LoopctlWeb.ArticleControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/articles" do
    test "creates and publishes a tenant-wide article with agent role by default", %{conn: conn} do
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
      # Publish-on-create is the default for every role, including agent (#133).
      assert body["data"]["status"] == "published"
      assert is_nil(body["data"]["project_id"])
      assert body["note"] =~ "published"
    end

    test "agent can stage a draft via draft: true", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Staged Draft",
          "body" => "stage me for later review",
          "category" => "pattern",
          "draft" => true
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
      assert body["note"] =~ "draft"
      assert body["note"] =~ "publish"
    end

    test "status: \"draft\" is honoured as the draft opt-in", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Draft Via Status",
          "body" => "status draft also stages",
          "category" => "pattern",
          "status" => "draft"
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
    end

    test "a default create that dedups onto an existing draft is returned unchanged (still draft)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Draft",
        "body" => "identical body content",
        "category" => "pattern"
      }

      # First create stages a draft explicitly.
      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/articles", Map.put(payload, "draft", true))
      |> json_response(201)

      # A second (default publish) create of the same title+body dedups onto the
      # existing draft — a pure no-op, so it is returned unchanged and is NOT
      # published.
      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "draft"
      # The note honestly explains the publish intent did not apply (an identical
      # draft was staged earlier) and gives an actually-reachable remedy.
      assert resp["note"] =~ "did not change it"
      assert resp["note"] =~ "publish"
      refute resp["note"] =~ "Created"
    end

    test "draft: true that dedups onto an existing draft says the intent is satisfied", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Draft Intent",
        "body" => "identical staged body",
        "category" => "pattern",
        "draft" => true
      }

      conn |> auth_conn(agent_key) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "draft"
      assert resp["note"] =~ "already existed"
    end

    test "dedup onto an existing published article does not claim it was 'created' now", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Dedup Published",
        "body" => "identical published body",
        "category" => "pattern"
      }

      # First call creates-and-publishes (default).
      first =
        conn |> auth_conn(agent_key) |> post(~p"/api/v1/articles", payload) |> json_response(201)

      assert first["data"]["status"] == "published"

      # Second identical call dedups onto the published article — a no-op.
      resp =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", payload)
        |> json_response(200)

      assert resp["deduplicated"] == true
      assert resp["data"]["status"] == "published"
      assert resp["note"] =~ "already existed"
      refute resp["note"] =~ "Created"
    end

    test "system scope is still gated to superadmin (agent gets system_scope_forbidden)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "System Scoped",
          "body" => "agent attempting a system-scoped article",
          "category" => "pattern",
          "scope" => "system"
        })

      body = json_response(conn, 403)
      assert body["error"]["code"] == "system_scope_forbidden"
    end

    test "another tenant's project_id returns 422 before any article is created", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      other_tenant = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other_tenant.id})
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Cross Tenant Project",
          "body" => "project ownership is validated before any side effect",
          "category" => "pattern",
          "project_id" => other_project.id
        })

      body = json_response(conn, 422)
      assert body["error"]["details"]["project_id"] != nil
    end

    test "a non-draft caller-supplied status is ignored; article publishes by default", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Cannot Create Archived",
          "body" => "archived is a workflow transition, not a create-time status",
          "category" => "pattern",
          "status" => "archived"
        })

      # archived/superseded are workflow transitions, not create-time statuses —
      # the server ignores them and applies the publish-on-create default.
      body = json_response(conn, 201)
      assert body["data"]["status"] == "published"
    end

    test "a legacy publish: true payload is harmless — it just publishes (the default)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Legacy Publish Flag",
          "body" => "old clients still send publish: true",
          "category" => "pattern",
          "publish" => true
        })

      # The `publish` flag is dropped server-side; the article publishes by default
      # anyway, so an old client gets a sensible result (no 403, no draft).
      body = json_response(conn, 201)
      assert body["data"]["status"] == "published"
    end

    test "status: \"draft\" wins over draft: false (explicit stage beats the absent opt-in)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Draft Precedence",
          "body" => "status draft is an explicit stage request; draft:false is not an opt-out",
          "category" => "pattern",
          "status" => "draft",
          "draft" => false
        })

      body = json_response(conn, 201)
      assert body["data"]["status"] == "draft"
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

    test "duplicate title with an identical body is idempotent (200, same id)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      payload = %{
        "title" => "Captured Video",
        "body" => "the captured summary",
        "category" => "reference",
        "tags" => ["hub"]
      }

      first = conn |> auth_conn(raw_key) |> post(~p"/api/v1/articles", payload)
      first_body = json_response(first, 201)
      first_id = first_body["data"]["id"]
      refute first_body["deduplicated"]

      # A concurrent/retried publish of the same content returns the same row with
      # a 200 (not 201) AND deduplicated: true, so callers/observers (incl. the MCP
      # layer that only sees a 2xx) can distinguish a dedup from a create.
      second = conn |> auth_conn(raw_key) |> post(~p"/api/v1/articles", payload)
      second_body = json_response(second, 200)
      assert second_body["data"]["id"] == first_id
      assert second_body["deduplicated"] == true
    end

    test "duplicate title with different content returns a clear 409 (not a retried 422)", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      _first =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Shared Heading",
          "body" => "first",
          "category" => "pattern"
        })
        |> json_response(201)

      second =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/articles", %{
          "title" => "Shared Heading",
          "body" => "second",
          "category" => "convention"
        })

      body = json_response(second, 409)
      assert body["error"]["status"] == 409
      assert body["error"]["code"] == "title_conflict"
      assert body["error"]["details"]["existing_article_id"]
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
