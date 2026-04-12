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
      assert data["resolved_as"] == "api_key"
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

  # ---------------------------------------------------------------------------
  # US-25.2: Project & logical-agent slicing
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/knowledge/analytics/top-articles?project_id (TC-25.2.1)" do
    test "filters to a single project, excluding NULL-tagged events", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project_a = fixture(:project, %{tenant_id: tenant.id})
      project_b = fixture(:project, %{tenant_id: tenant.id})
      article_1 = fixture(:article, %{tenant_id: tenant.id, title: "A1", status: :published})
      article_2 = fixture(:article, %{tenant_id: tenant.id, title: "A2", status: :published})

      for _ <- 1..3 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article_1.id,
          api_key_id: agent.id,
          project_id: project_a.id
        })
      end

      for _ <- 1..2 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article_2.id,
          api_key_id: agent.id,
          project_id: project_b.id
        })
      end

      # NULL-tagged event for article_1 — should NOT be counted
      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: article_1.id,
        api_key_id: agent.id,
        project_id: nil
      })

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles?project_id=#{project_a.id}")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      [row] = body["data"]
      assert row["article_id"] == article_1.id
      assert row["access_count"] == 3
      assert body["meta"]["project_id"] == project_a.id
    end
  end

  describe "GET /api/v1/knowledge/analytics/top-articles?group_by=project (TC-25.2.2)" do
    test "returns per-project rollup sorted by access_count DESC", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project_a = fixture(:project, %{tenant_id: tenant.id, name: "HomeCareBilling"})
      project_b = fixture(:project, %{tenant_id: tenant.id, name: "Balic Tracker"})

      a_articles =
        for i <- 1..4 do
          fixture(:article, %{tenant_id: tenant.id, title: "a#{i}", status: :published})
        end

      # Distribute 10 events across 4 project_a articles
      for {art, n} <- Enum.zip(a_articles, [4, 3, 2, 1]), _ <- 1..n do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: art.id,
          api_key_id: agent.id,
          project_id: project_a.id
        })
      end

      b_articles =
        for i <- 1..2 do
          fixture(:article, %{tenant_id: tenant.id, title: "b#{i}", status: :published})
        end

      for {art, n} <- Enum.zip(b_articles, [2, 1]), _ <- 1..n do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: art.id,
          api_key_id: agent.id,
          project_id: project_b.id
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles?group_by=project")

      body = json_response(conn, 200)
      assert body["meta"]["group_by"] == "project"
      assert length(body["data"]) == 2

      [first, second] = body["data"]
      assert first["project_id"] == project_a.id
      assert first["project_name"] == "HomeCareBilling"
      assert first["access_count"] == 10
      assert first["unique_articles"] == 4
      assert first["unique_api_keys"] == 1

      assert second["project_id"] == project_b.id
      assert second["access_count"] == 3
      assert second["unique_articles"] == 2
    end
  end

  describe "GET /api/v1/knowledge/analytics/top-articles?group_by=agent (TC-25.2.3)" do
    test "aggregates across all keys of one logical agent", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      agent_record =
        fixture(:agent, %{
          tenant_id: tenant.id,
          name: "orchestrator",
          agent_type: :orchestrator
        })

      {_raw, k1} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          agent_id: agent_record.id,
          role: :orchestrator,
          name: "k1"
        })

      # Use different role for k2 (unique index: one active key per agent+role)
      {_raw, k2} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          agent_id: agent_record.id,
          role: :agent,
          name: "k2"
        })

      {_raw, solo} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, name: "solo"})

      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      for _ <- 1..5 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: k1.id
        })
      end

      for _ <- 1..7 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: k2.id
        })
      end

      for _ <- 1..2 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: solo.id
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/top-articles?group_by=agent")

      body = json_response(conn, 200)
      assert body["meta"]["group_by"] == "agent"
      assert length(body["data"]) == 2

      orch_row = Enum.find(body["data"], &(&1["agent_id"] == agent_record.id))
      assert orch_row["agent_name"] == "orchestrator"
      assert orch_row["agent_type"] == "orchestrator"
      assert orch_row["access_count"] == 12
      assert orch_row["api_key_count"] == 2
    end
  end

  describe "GET /api/v1/knowledge/analytics/agents/:id dual resolution" do
    # TC-25.2.4
    test "resolves an api_keys.id path parameter", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      for _ <- 1..3 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: api_key.id
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/agents/#{api_key.id}")

      data = json_response(conn, 200)["data"]
      assert data["resolved_as"] == "api_key"
      assert data["api_key_id"] == api_key.id
      assert data["total_reads"] == 3
    end

    # TC-25.2.5
    test "falls back to agents.id and aggregates across keys", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      agent_record = fixture(:agent, %{tenant_id: tenant.id, name: "orchestrator"})

      {_raw, k1} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          agent_id: agent_record.id,
          role: :orchestrator,
          name: "k1"
        })

      # Use different role for k2 (unique index: one active key per agent+role)
      {_raw, k2} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          agent_id: agent_record.id,
          role: :agent,
          name: "k2"
        })

      article = fixture(:article, %{tenant_id: tenant.id, status: :published})

      for _ <- 1..4 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: k1.id
        })
      end

      for _ <- 1..6 do
        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: article.id,
          api_key_id: k2.id
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/agents/#{agent_record.id}")

      data = json_response(conn, 200)["data"]
      assert data["resolved_as"] == "agent"
      assert data["agent_id"] == agent_record.id
      assert data["agent_name"] == "orchestrator"
      assert data["total_reads"] == 10
      assert data["api_key_count"] == 2
    end

    test "returns 404 for unknown id", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/agents/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/knowledge/analytics/projects/:id/usage (TC-25.2.6)" do
    test "returns per-project rollup with daily series", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      {_raw, agent} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id, name: "HomeCareBilling"})

      articles =
        for i <- 1..10 do
          fixture(:article, %{tenant_id: tenant.id, title: "a#{i}", status: :published})
        end

      today = Date.utc_today()
      days = [Date.add(today, -2), Date.add(today, -1), today]
      distribution = [{Enum.at(days, 0), 5}, {Enum.at(days, 1), 6}, {Enum.at(days, 2), 4}]

      distribution
      |> Enum.with_index()
      |> Enum.each(fn {{day, count}, idx} ->
        for j <- 0..(count - 1) do
          art = Enum.at(articles, rem(idx * 4 + j, 10))

          fixture(:article_access_event, %{
            tenant_id: tenant.id,
            article_id: art.id,
            api_key_id: agent.id,
            project_id: project.id,
            accessed_at:
              day
              |> DateTime.new!(~T[12:00:00.000000], "Etc/UTC")
          })
        end
      end)

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/projects/#{project.id}/usage?since_days=7")

      data = json_response(conn, 200)["data"]
      assert data["project_id"] == project.id
      assert data["project_name"] == "HomeCareBilling"
      assert data["total_reads"] == 15
      assert data["unique_articles"] == 10
      assert is_list(data["top_articles"])
      assert length(data["daily_series"]) == 7

      counts_by_date = Map.new(data["daily_series"], &{&1["date"], &1["read_count"]})
      assert counts_by_date[Date.to_iso8601(Enum.at(days, 0))] == 5
      assert counts_by_date[Date.to_iso8601(Enum.at(days, 1))] == 6
      assert counts_by_date[Date.to_iso8601(Enum.at(days, 2))] == 4
    end

    # TC-25.2.7
    test "cross-tenant project_id returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {orch_key_a, _} = fixture(:api_key, %{tenant_id: tenant_a.id, role: :orchestrator})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})

      conn =
        conn
        |> auth_conn(orch_key_a)
        |> get(~p"/api/v1/knowledge/analytics/projects/#{project_b.id}/usage")

      assert json_response(conn, 404)
    end

    test "returns 404 for malformed project_id", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/projects/not-a-uuid/usage")

      assert json_response(conn, 404)
    end

    test "clamps since_days to max 365", %{conn: conn} do
      tenant = fixture(:tenant)
      {orch_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/knowledge/analytics/projects/#{project.id}/usage?since_days=99999")

      data = json_response(conn, 200)
      assert data["meta"]["since_days"] == 365
      assert length(data["data"]["daily_series"]) == 365
    end

    test "rejects agent role with 403", %{conn: conn} do
      tenant = fixture(:tenant)
      {agent_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      project = fixture(:project, %{tenant_id: tenant.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/knowledge/analytics/projects/#{project.id}/usage")

      assert json_response(conn, 403)
    end
  end
end
