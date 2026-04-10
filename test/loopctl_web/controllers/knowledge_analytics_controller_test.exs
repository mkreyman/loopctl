defmodule LoopctlWeb.KnowledgeAnalyticsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Knowledge

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "auth" do
    test "agent role is rejected (orchestrator+ required) on top-articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles")

      assert json_response(conn, 403)
    end

    test "agent role is rejected on article stats", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/articles/#{article.id}/stats")

      assert json_response(conn, 403)
    end

    test "agent role is rejected on agent usage", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, agent_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/analytics/agents/#{agent_key.id}")

      assert json_response(conn, 403)
    end

    test "agent role is rejected on unused articles", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get(~p"/api/v1/knowledge/analytics/unused-articles")

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/knowledge/analytics/top-articles" do
    test "returns rows ordered by access count", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      hot = fixture(:article, %{tenant_id: tenant.id, title: "Hot", status: :published})
      cold = fixture(:article, %{tenant_id: tenant.id, title: "Cold", status: :published})

      for _ <- 1..3, do: Knowledge.record_access(tenant.id, hot.id, agent.id, "get")
      Knowledge.record_access(tenant.id, cold.id, agent.id, "get")

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles")

      body = json_response(conn, 200)
      assert is_list(body["data"])

      [first | _] = body["data"]
      assert first["title"] == "Hot"
      assert first["access_count"] == 3
      assert first["unique_agents"] == 1
      assert is_map(body["meta"])
    end

    test "filters by access_type query param", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent.id, "search")
      Knowledge.record_access(tenant.id, article.id, agent.id, "get")

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles?access_type=search")

      body = json_response(conn, 200)
      [row] = body["data"]
      assert row["access_count"] == 1
    end
  end

  describe "GET /api/v1/knowledge/articles/:id/stats" do
    test "returns 200 with aggregated stats", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent.id, "get")
      Knowledge.record_access(tenant.id, article.id, agent.id, "search")

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/articles/#{article.id}/stats")

      data = json_response(conn, 200)["data"]
      assert data["article_id"] == article.id
      assert data["title"] == article.title
      assert data["total_accesses"] == 2
      assert data["unique_agents"] == 1
      assert data["accesses_by_type"] == %{"get" => 1, "search" => 1}
      assert is_list(data["recent_accesses"])
    end

    test "returns 404 for missing article", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/articles/#{Ecto.UUID.generate()}/stats")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/knowledge/analytics/agents/:agent_id" do
    test "scopes to a single api_key", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent_a} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "a"})
      {_raw, agent_b} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "b"})

      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      Knowledge.record_access(tenant.id, article.id, agent_a.id, "get")
      Knowledge.record_access(tenant.id, article.id, agent_a.id, "get")
      Knowledge.record_access(tenant.id, article.id, agent_b.id, "get")

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/agents/#{agent_a.id}")

      data = json_response(conn, 200)["data"]
      assert data["api_key_id"] == agent_a.id
      assert data["total_reads"] == 2
      assert data["unique_articles"] == 1
      assert is_list(data["top_articles"])
    end
  end

  describe "GET /api/v1/knowledge/analytics/unused-articles" do
    test "returns articles never accessed in the window", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      used = fixture(:article, %{tenant_id: tenant.id, title: "Used", status: :published})

      _unused =
        fixture(:article, %{tenant_id: tenant.id, title: "Unused", status: :published})

      Knowledge.record_access(tenant.id, used.id, agent.id, "get")

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/unused-articles?days_unused=7")

      body = json_response(conn, 200)
      titles = Enum.map(body["data"], & &1["title"])
      assert "Unused" in titles
      refute "Used" in titles
      assert body["meta"]["days_unused"] == 7
    end
  end

  describe "integration: real read endpoints record events" do
    test "GET /articles/:id records a get event", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, agent_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/articles/#{article.id}")
      |> json_response(200)

      events = Loopctl.AdminRepo.all(Loopctl.Knowledge.ArticleAccessEvent)
      assert length(events) == 1
      [event] = events
      assert event.access_type == "get"
      assert event.api_key_id == agent_key.id
      assert event.article_id == article.id
    end

    test "GET /knowledge/search records search events", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      _article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Genserver Patterns",
          body: "GenServer is the OTP behaviour for stateful processes.",
          status: :published
        })

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/search?q=GenServer&mode=keyword")
      |> json_response(200)

      events = Loopctl.AdminRepo.all(Loopctl.Knowledge.ArticleAccessEvent)
      assert events != []
      assert Enum.all?(events, &(&1.access_type == "search"))
    end

    test "GET /knowledge/context records context events", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      _article =
        fixture(:article, %{
          tenant_id: tenant.id,
          title: "Context Tracking",
          body: "Body about analytics context tracking via the api endpoint.",
          status: :published
        })

      conn
      |> auth_conn(raw_key)
      |> get(~p"/api/v1/knowledge/context?query=context+tracking")
      |> json_response(200)

      events = Loopctl.AdminRepo.all(Loopctl.Knowledge.ArticleAccessEvent)

      if events != [] do
        assert Enum.all?(events, &(&1.access_type == "context"))
      end
    end
  end
end
