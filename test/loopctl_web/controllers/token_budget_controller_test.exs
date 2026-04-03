defmodule LoopctlWeb.TokenBudgetControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_project_with_keys do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    {user_key, _user_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    agent = fixture(:agent, %{tenant_id: tenant.id})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      story: story,
      user_key: user_key,
      agent_key: agent_key,
      agent: agent
    }
  end

  # --- POST /api/v1/token-budgets ---

  describe "POST /api/v1/token-budgets" do
    test "creates a budget for a story", %{conn: conn} do
      %{story: story, user_key: user_key, tenant: tenant} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id,
          "budget_millicents" => 500_000
        })

      body = json_response(conn, 201)
      budget = body["token_budget"]

      assert budget["scope_type"] == "story"
      assert budget["scope_id"] == story.id
      assert budget["budget_millicents"] == 500_000
      assert budget["alert_threshold_pct"] == 80
      assert budget["budget_dollars"] == "5.00"
      assert budget["current_spend_millicents"] == 0
      assert budget["remaining_millicents"] == 500_000
      assert budget["tenant_id"] == tenant.id
    end

    test "creates a budget for a project", %{conn: conn} do
      %{project: project, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "project",
          "scope_id" => project.id,
          "budget_millicents" => 10_000_000
        })

      body = json_response(conn, 201)
      assert body["token_budget"]["scope_type"] == "project"
    end

    test "creates a budget for an epic", %{conn: conn} do
      %{epic: epic, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "epic",
          "scope_id" => epic.id,
          "budget_millicents" => 2_000_000
        })

      body = json_response(conn, 201)
      assert body["token_budget"]["scope_type"] == "epic"
    end

    test "accepts optional fields", %{conn: conn} do
      %{story: story, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id,
          "budget_millicents" => 500_000,
          "budget_input_tokens" => 100_000,
          "budget_output_tokens" => 50_000,
          "alert_threshold_pct" => 90,
          "metadata" => %{"reason" => "test"}
        })

      body = json_response(conn, 201)
      budget = body["token_budget"]

      assert budget["budget_input_tokens"] == 100_000
      assert budget["budget_output_tokens"] == 50_000
      assert budget["alert_threshold_pct"] == 90
      assert budget["metadata"] == %{"reason" => "test"}
    end

    test "returns 409 on duplicate budget", %{conn: conn} do
      %{story: story, user_key: user_key} = setup_project_with_keys()

      params = %{
        "scope_type" => "story",
        "scope_id" => story.id,
        "budget_millicents" => 500_000
      }

      conn
      |> auth_conn(user_key)
      |> post(~p"/api/v1/token-budgets", params)

      conn2 =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", params)

      assert json_response(conn2, 409)
    end

    test "returns 404 for nonexistent scope entity", %{conn: conn} do
      %{user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => Ecto.UUID.generate(),
          "budget_millicents" => 500_000
        })

      assert json_response(conn, 404)
    end

    test "returns 422 for missing budget_millicents", %{conn: conn} do
      %{story: story, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id
        })

      assert json_response(conn, 422)
    end

    test "returns 422 for zero budget_millicents", %{conn: conn} do
      %{story: story, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id,
          "budget_millicents" => 0
        })

      assert json_response(conn, 422)
    end

    test "agent role cannot create budgets", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id,
          "budget_millicents" => 500_000
        })

      assert json_response(conn, 403)
    end
  end

  # --- GET /api/v1/token-budgets ---

  describe "GET /api/v1/token-budgets" do
    test "lists budgets for tenant", %{conn: conn} do
      %{
        tenant: tenant,
        project: project,
        story: story,
        agent_key: agent_key,
        agent: agent
      } = setup_project_with_keys()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      # Add some spend
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 3000
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets")

      body = json_response(conn, 200)

      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 2

      # Each entry should have spend info
      Enum.each(body["data"], fn entry ->
        assert Map.has_key?(entry, "current_spend_millicents")
        assert Map.has_key?(entry, "remaining_millicents")
        assert Map.has_key?(entry, "budget_dollars")
      end)
    end

    test "filters by scope_type", %{conn: conn} do
      %{tenant: tenant, project: project, story: story, agent_key: agent_key} =
        setup_project_with_keys()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :project,
        scope_id: project.id
      })

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets?scope_type=story")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
      assert hd(body["data"])["scope_type"] == "story"
    end

    test "filters by scope_id", %{conn: conn} do
      %{tenant: tenant, story: story, agent_key: agent_key} = setup_project_with_keys()

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story.id
      })

      story2 = fixture(:story, %{tenant_id: tenant.id})

      fixture(:token_budget, %{
        tenant_id: tenant.id,
        scope_type: :story,
        scope_id: story2.id
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets?scope_id=#{story.id}")

      body = json_response(conn, 200)
      assert body["meta"]["total_count"] == 1
    end

    test "supports pagination", %{conn: conn} do
      %{tenant: tenant, agent_key: agent_key} = setup_project_with_keys()

      for _i <- 1..5 do
        story = fixture(:story, %{tenant_id: tenant.id})

        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })
      end

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["total_pages"] == 3
    end
  end

  # --- GET /api/v1/token-budgets/:id ---

  describe "GET /api/v1/token-budgets/:id" do
    test "returns a single budget with spend info", %{conn: conn} do
      %{
        tenant: tenant,
        story: story,
        agent_key: agent_key,
        agent: agent
      } = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        cost_millicents: 3000
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets/#{budget.id}")

      body = json_response(conn, 200)
      result = body["token_budget"]

      assert result["id"] == budget.id
      assert result["budget_millicents"] == 500_000
      assert result["current_spend_millicents"] == 3000
      assert result["remaining_millicents"] == 497_000
    end

    test "returns 404 for nonexistent budget", %{conn: conn} do
      %{agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/token-budgets/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  # --- PATCH /api/v1/token-budgets/:id ---

  describe "PATCH /api/v1/token-budgets/:id" do
    test "updates budget_millicents", %{conn: conn} do
      %{tenant: tenant, story: story, user_key: user_key} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      conn =
        conn
        |> auth_conn(user_key)
        |> patch(~p"/api/v1/token-budgets/#{budget.id}", %{
          "budget_millicents" => 1_000_000
        })

      body = json_response(conn, 200)
      assert body["token_budget"]["budget_millicents"] == 1_000_000
    end

    test "updates alert_threshold_pct", %{conn: conn} do
      %{tenant: tenant, story: story, user_key: user_key} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      conn =
        conn
        |> auth_conn(user_key)
        |> patch(~p"/api/v1/token-budgets/#{budget.id}", %{
          "alert_threshold_pct" => 95
        })

      body = json_response(conn, 200)
      assert body["token_budget"]["alert_threshold_pct"] == 95
    end

    test "returns 404 for nonexistent budget", %{conn: conn} do
      %{user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> patch(~p"/api/v1/token-budgets/#{Ecto.UUID.generate()}", %{
          "budget_millicents" => 100
        })

      assert json_response(conn, 404)
    end

    test "agent role cannot update budgets", %{conn: conn} do
      %{tenant: tenant, story: story, agent_key: agent_key} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      conn =
        conn
        |> auth_conn(agent_key)
        |> patch(~p"/api/v1/token-budgets/#{budget.id}", %{
          "budget_millicents" => 1_000_000
        })

      assert json_response(conn, 403)
    end
  end

  # --- DELETE /api/v1/token-budgets/:id ---

  describe "DELETE /api/v1/token-budgets/:id" do
    test "deletes a budget", %{conn: conn} do
      %{tenant: tenant, story: story, user_key: user_key} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      conn =
        conn
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/token-budgets/#{budget.id}")

      body = json_response(conn, 200)
      assert body["token_budget"]["id"] == budget.id
      assert body["token_budget"]["deleted"] == true
    end

    test "returns 404 for nonexistent budget", %{conn: conn} do
      %{user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> delete(~p"/api/v1/token-budgets/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "agent role cannot delete budgets", %{conn: conn} do
      %{tenant: tenant, story: story, agent_key: agent_key} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant.id,
          scope_type: :story,
          scope_id: story.id
        })

      conn =
        conn
        |> auth_conn(agent_key)
        |> delete(~p"/api/v1/token-budgets/#{budget.id}")

      assert json_response(conn, 403)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "cross-tenant budget creation returns 404", %{conn: conn} do
      %{story: story} = setup_project_with_keys()

      tenant_b = fixture(:tenant)
      {key_b, _} = fixture(:api_key, %{tenant_id: tenant_b.id, role: :user})

      conn =
        conn
        |> auth_conn(key_b)
        |> post(~p"/api/v1/token-budgets", %{
          "scope_type" => "story",
          "scope_id" => story.id,
          "budget_millicents" => 500_000
        })

      assert json_response(conn, 404)
    end

    test "cross-tenant budget listing returns empty", %{conn: conn} do
      %{tenant: tenant_a, story: story} = setup_project_with_keys()

      fixture(:token_budget, %{
        tenant_id: tenant_a.id,
        scope_type: :story,
        scope_id: story.id
      })

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/token-budgets")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "cross-tenant budget show returns 404", %{conn: conn} do
      %{tenant: tenant_a, story: story} = setup_project_with_keys()

      budget =
        fixture(:token_budget, %{
          tenant_id: tenant_a.id,
          scope_type: :story,
          scope_id: story.id
        })

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/token-budgets/#{budget.id}")

      assert json_response(conn, 404)
    end
  end
end
