defmodule LoopctlWeb.KnowledgeIndexControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/index" do
    test "clamps a limit above the maximum page size (never rejects), reporting effective meta.limit (#148 A1)",
         %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      resp =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?limit=1001")
        |> json_response(200)

      assert resp["meta"]["limit"] == 1000
    end

    test "returns lightweight catalog grouped by category, drafts excluded", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Published articles in different categories
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        status: :published,
        tags: ["elixir"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Convention B",
        category: :convention,
        status: :published,
        tags: ["naming"]
      })

      # Draft article -- should be excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Draft Article",
        category: :finding,
        status: :draft,
        tags: []
      })

      # Archived article -- should be excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Old Article",
        category: :decision,
        status: :archived,
        tags: []
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index")

      body = json_response(conn, 200)

      # Should have data grouped by category
      assert is_map(body["data"])
      assert Map.has_key?(body["data"], "pattern")
      assert Map.has_key?(body["data"], "convention")
      refute Map.has_key?(body["data"], "finding")
      refute Map.has_key?(body["data"], "decision")

      # Default projection is id, title, category only (Issue #117): tags,
      # status, and updated_at are dropped unless requested via `fields`.
      [pattern_article] = body["data"]["pattern"]
      assert pattern_article["id"]
      assert pattern_article["title"] == "Pattern A"
      assert pattern_article["category"] == "pattern"
      refute Map.has_key?(pattern_article, "tags")
      refute Map.has_key?(pattern_article, "status")
      refute Map.has_key?(pattern_article, "updated_at")
      refute Map.has_key?(pattern_article, "body")
      refute Map.has_key?(pattern_article, "embedding")
      refute Map.has_key?(pattern_article, "metadata")

      # Verify meta
      assert body["meta"]["total_count"] == 2
      assert body["meta"]["truncated"] == false
      assert body["meta"]["categories"]["pattern"] == 1
      assert body["meta"]["categories"]["convention"] == 1
    end

    test "returns empty result when no published articles exist", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index")

      body = json_response(conn, 200)
      assert body["data"] == %{}
      assert body["meta"]["total_count"] == 0
      assert body["meta"]["truncated"] == false
      assert body["meta"]["categories"] == %{}
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/index")
      assert json_response(conn, 401)
    end
  end

  describe "fields projection (Issue #117)" do
    test "fields param adds requested fields and always includes id", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        status: :published,
        tags: ["elixir", "ecto"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?fields=tags,updated_at")

      body = json_response(conn, 200)
      [article] = body["data"]["pattern"]

      # id and category are always included even when not requested (category is
      # the grouping key, so the object stays self-describing when flattened).
      assert article["id"]
      assert article["category"] == "pattern"
      assert article["tags"] == ["elixir", "ecto"]
      assert article["updated_at"]
      refute Map.has_key?(article, "title")
      refute Map.has_key?(article, "status")

      # meta echoes the applied projection and exposes has_more (alias of truncated).
      assert body["meta"]["fields"] == ["id", "category", "tags", "updated_at"]
      assert body["meta"]["has_more"] == false
      assert body["meta"]["truncated"] == false
    end

    test "invalid fields returns 400 rather than silently ignoring them", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?fields=title,bogus")

      assert json_response(conn, 400)
    end

    test "a non-string fields param returns 400, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # ?fields[]=x parses to a list, which must be rejected cleanly (400),
      # not raise a FunctionClauseError (500).
      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/knowledge/index?fields[]=tags")

      assert json_response(conn, 400)
    end

    test "a repeated valid field is de-duplicated, not rejected as invalid", %{conn: _conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Pattern A",
        category: :pattern,
        status: :published,
        tags: ["elixir"]
      })

      # `fields=id,id` / `fields=tags,tags` must succeed (200), not 400 — a
      # repeated valid field is not an invalid field.
      for query <- ["fields=id,id", "fields=tags,tags", "fields=id,title,title"] do
        conn =
          build_conn()
          |> auth_conn(raw_key)
          |> get(~p"/api/v1/knowledge/index?#{query}")

        body = json_response(conn, 200)
        [article] = body["data"]["pattern"]
        assert article["id"]
      end
    end
  end

  describe "GET /api/v1/projects/:project_id/knowledge/index" do
    test "project-scoped includes tenant-wide + project-specific articles", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other_project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Tenant-wide article (nil project_id) -- should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide Pattern",
        category: :pattern,
        status: :published
      })

      # Project-specific article -- should be included
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Project Convention",
        category: :convention,
        status: :published
      })

      # Other project's article -- should be excluded
      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: other_project.id,
        title: "Other Project Finding",
        category: :finding,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/projects/#{project.id}/knowledge/index")

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 2
      assert Map.has_key?(body["data"], "pattern")
      assert Map.has_key?(body["data"], "convention")
      refute Map.has_key?(body["data"], "finding")

      # Verify tenant-wide article is included
      [pattern] = body["data"]["pattern"]
      assert pattern["title"] == "Tenant Wide Pattern"

      # Verify project-specific article is included
      [convention] = body["data"]["convention"]
      assert convention["title"] == "Project Convention"
    end

    test "a malformed (non-UUID) project_id yields tenant-wide results, not a 500", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Tenant Wide Pattern",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/projects/not-a-uuid/knowledge/index")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      [pattern] = body["data"]["pattern"]
      assert pattern["title"] == "Tenant Wide Pattern"
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Article",
        category: :pattern,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Article",
        category: :pattern,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/index")

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 1
      [article] = body["data"]["pattern"]
      assert article["title"] == "Tenant A Article"
    end
  end

  describe "sorting within category" do
    test "articles are sorted by updated_at desc within each category", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Create articles with different updated_at times
      older =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Older Pattern",
          category: :pattern,
          status: :published
        })

      newer =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Newer Pattern",
          category: :pattern,
          status: :published
        })

      # Force different updated_at timestamps
      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3600, :second)

      import Ecto.Query

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^older.id),
        set: [updated_at: one_hour_ago]
      )

      Loopctl.AdminRepo.update_all(
        from(a in Loopctl.Knowledge.Article, where: a.id == ^newer.id),
        set: [updated_at: now]
      )

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index")

      body = json_response(conn, 200)

      patterns = body["data"]["pattern"]
      assert length(patterns) == 2
      # Newer should come first (desc order)
      assert Enum.at(patterns, 0)["title"] == "Newer Pattern"
      assert Enum.at(patterns, 1)["title"] == "Older Pattern"
    end
  end

  describe "filtering and pagination (Issue #109)" do
    test "category filter returns only that category", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "A Reference",
        category: :reference,
        status: :published
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "A Convention",
        category: :convention,
        status: :published
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?category=reference")

      body = json_response(conn, 200)

      assert Map.keys(body["data"]) == ["reference"]
      assert body["meta"]["total_count"] == 1
      assert body["meta"]["categories"] == %{"reference" => 1}
    end

    test "tags filter matches articles carrying ANY listed tag", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Hub One",
        category: :reference,
        status: :published,
        tags: ["hub", "elixir"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Not A Hub",
        category: :reference,
        status: :published,
        tags: ["elixir"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?tags=hub")

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 1
      [article] = body["data"]["reference"]
      assert article["title"] == "Hub One"
    end

    test "offset/limit paginate deterministically without dropping later categories", %{
      conn: conn
    } do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # 2 articles per category across all 5 categories = 10 total.
      categories = [:pattern, :convention, :decision, :finding, :reference]

      for cat <- categories, i <- 1..2 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "#{cat}-#{i}",
          category: cat,
          status: :published
        })
      end

      # Page through with limit=3 and collect every id; assert full coverage,
      # including the alphabetically-last category (reference) which the old
      # truncation-at-1000 behavior would have dropped.
      collect_ids = fn offset ->
        body =
          conn
          |> auth_conn(raw_key)
          |> get(~p"/api/v1/knowledge/index?limit=3&offset=#{offset}")
          |> json_response(200)

        body
      end

      pages = Enum.map([0, 3, 6, 9], collect_ids)

      all_ids =
        pages
        |> Enum.flat_map(fn body ->
          body["data"] |> Map.values() |> List.flatten() |> Enum.map(& &1["id"])
        end)

      assert length(all_ids) == 10
      assert length(Enum.uniq(all_ids)) == 10, "pagination must not repeat rows"

      # categories meta reports the full distribution even on a partial page
      first_page = hd(pages)
      assert first_page["meta"]["total_count"] == 10
      assert first_page["meta"]["offset"] == 0
      assert first_page["meta"]["limit"] == 3
      assert first_page["meta"]["truncated"] == true
      assert first_page["meta"]["categories"]["reference"] == 2

      # last page is not truncated
      last_page = List.last(pages)
      assert last_page["meta"]["truncated"] == false
    end

    test "invalid category returns 400 rather than silently ignoring it", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index?category=bogus")

      body = json_response(conn, 400)
      assert body["error"]
    end
  end

  describe "correct grouping with many articles" do
    test "20 articles return correct grouping (no N+1)", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      categories = [:pattern, :convention, :decision, :finding, :reference]

      # Create 20 published articles (4 per category)
      for i <- 1..20 do
        category = Enum.at(categories, rem(i - 1, 5))

        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Article #{i}",
          category: category,
          status: :published,
          tags: ["tag-#{i}"]
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/index")

      body = json_response(conn, 200)

      assert body["meta"]["total_count"] == 20
      assert body["meta"]["truncated"] == false

      # All 5 categories should be present
      assert map_size(body["data"]) == 5

      # Each category should have exactly 4 articles
      for {_cat, articles} <- body["data"] do
        assert length(articles) == 4
      end

      # Category counts should match
      for {cat, count} <- body["meta"]["categories"] do
        assert count == 4, "Expected category #{cat} to have 4 articles, got #{count}"
      end
    end
  end
end
