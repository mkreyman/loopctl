defmodule LoopctlWeb.KnowledgeSearchControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "GET /api/v1/knowledge/search" do
    test "keyword search returns snippets without body", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic multi-step database operations.",
        category: :pattern,
        status: :published,
        tags: ["ecto", "transactions"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "Ecto", mode: "keyword"})

      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["data"] != []

      result = List.first(body["data"])
      assert result["id"]
      assert result["title"] == "Ecto Multi Pattern"
      assert result["category"] == "pattern"
      assert result["tags"] == ["ecto", "transactions"]
      assert is_number(result["score"])
      assert result["score"] > 0

      # Snippet is present, body is not
      assert is_binary(result["snippet"]) or is_nil(result["snippet"])
      refute Map.has_key?(result, "body")

      # Meta is present
      assert body["meta"]["total_count"] >= 1
      assert body["meta"]["limit"] == 10
      assert body["meta"]["offset"] == 0
    end

    test "combined mode is default when mode param is omitted", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Test Pattern",
        body: "A test body for combined search default mode.",
        category: :pattern,
        status: :published,
        tags: ["test"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test"})

      body = json_response(conn, 200)

      # Should succeed (combined is default)
      assert is_list(body["data"])
      assert is_map(body["meta"])
    end

    test "missing q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search")

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "q"
    end

    test "empty q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: ""})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "q"
    end

    test "q exceeding 500 characters returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      long_query = String.duplicate("a", 501)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: long_query})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "500"
    end

    test "semantic mode returns 503 on embedding failure", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      expect(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
        {:error, :service_unavailable}
      end)

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test query", mode: "semantic"})

      body = json_response(conn, 503)
      assert body["error"]["status"] == 503
      assert body["error"]["message"] =~ "Embedding service unavailable"
    end

    test "filters by project_id, category, and tags", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant.id,
        project_id: project.id,
        title: "Filtered Pattern Ecto",
        body: "Ecto pattern for filtering test.",
        category: :pattern,
        status: :published,
        tags: ["ecto", "filtering"]
      })

      fixture(:article, %{
        tenant_id: tenant.id,
        title: "Unrelated Convention Ecto",
        body: "Ecto convention that should not match filters.",
        category: :convention,
        status: :published,
        tags: ["naming"]
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "Ecto",
          mode: "keyword",
          project_id: project.id,
          category: "pattern",
          tags: "ecto"
        })

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert List.first(body["data"])["title"] == "Filtered Pattern Ecto"
    end

    test "invalid mode returns 400 listing valid modes", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "test", mode: "invalid"})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
      assert body["error"]["message"] =~ "keyword"
      assert body["error"]["message"] =~ "semantic"
      assert body["error"]["message"] =~ "combined"
    end

    test "pagination with limit and offset", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      # Create 5 articles with "pagination" in the body
      for i <- 1..5 do
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Pagination Article #{i}",
          body: "Content about pagination and testing for article number #{i}.",
          category: :pattern,
          status: :published,
          tags: ["pagination"]
        })
      end

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{
          q: "pagination",
          mode: "keyword",
          limit: "2",
          offset: "1"
        })

      body = json_response(conn, 200)

      assert body["meta"]["limit"] == 2
      assert body["meta"]["offset"] == 1
      assert length(body["data"]) <= 2
    end

    test "tenant isolation — tenant A cannot see tenant B's articles", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {raw_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent})

      fixture(:article, %{
        tenant_id: tenant_a.id,
        title: "Tenant A Isolation Article",
        body: "Content for isolation test in tenant A.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      fixture(:article, %{
        tenant_id: tenant_b.id,
        title: "Tenant B Isolation Article",
        body: "Content for isolation test in tenant B.",
        category: :pattern,
        status: :published,
        tags: ["isolation"]
      })

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> get(~p"/api/v1/knowledge/search", %{q: "isolation", mode: "keyword"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert List.first(body["data"])["title"] == "Tenant A Isolation Article"
    end

    test "unauthenticated returns 401", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/knowledge/search", %{q: "test"})
      assert json_response(conn, 401)
    end

    test "whitespace-only q returns 400", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/search", %{q: "   "})

      body = json_response(conn, 400)
      assert body["error"]["status"] == 400
    end
  end
end
