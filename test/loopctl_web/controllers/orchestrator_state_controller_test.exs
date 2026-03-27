defmodule LoopctlWeb.OrchestratorStateControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "PUT /api/v1/orchestrator/state/:project_id" do
    test "creates new state with version 0", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"current_epic" => 3, "completed" => ["1.1"]},
          "version" => 0
        })

      body = json_response(conn, 200)
      state = body["state"]

      assert state["state_key"] == "main"
      assert state["state_data"] == %{"current_epic" => 3, "completed" => ["1.1"]}
      assert state["version"] == 1
      assert state["project_id"] == project.id
      assert state["tenant_id"] == tenant.id
    end

    test "updates existing state with correct version", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{"epic" => 3},
        version: 5
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"epic" => 4},
          "version" => 5
        })

      body = json_response(conn, 200)
      assert body["state"]["version"] == 6
      assert body["state"]["state_data"] == %{"epic" => 4}
    end

    test "returns 409 on version mismatch", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{},
        version: 3
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"update" => true},
          "version" => 2
        })

      assert json_response(conn, 409)
    end

    test "returns 422 when state_key is missing", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_data" => %{"data" => true},
          "version" => 0
        })

      assert json_response(conn, 422)
    end

    test "returns 404 for non-existent project", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      fake_id = Ecto.UUID.generate()

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{fake_id}", %{
          "state_key" => "main",
          "state_data" => %{},
          "version" => 0
        })

      assert json_response(conn, 404)
    end

    test "returns 403 for agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{},
          "version" => 0
        })

      assert json_response(conn, 403)
    end

    test "returns 403 for user role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{},
          "version" => 0
        })

      assert json_response(conn, 403)
    end

    test "tenant isolation: cross-tenant returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {raw_key_b, _api_key} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> put("/api/v1/orchestrator/state/#{project_a.id}", %{
          "state_key" => "main",
          "state_data" => %{},
          "version" => 0
        })

      assert json_response(conn, 404)
    end

    test "creates audit log entry on save", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn
      |> auth_conn(raw_key)
      |> put("/api/v1/orchestrator/state/#{project.id}", %{
        "state_key" => "main",
        "state_data" => %{"step" => 1},
        "version" => 0
      })

      {:ok, %{data: entries}} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "orchestrator_state",
          action: "saved"
        )

      assert length(entries) == 1
      [entry] = entries
      assert entry.new_state["version"] == 1
      assert entry.new_state["state_data"] == %{"step" => 1}
    end

    test "state_data accepts arbitrary JSON structures", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      large_data = %{
        "epics" => Enum.map(1..50, &%{"id" => &1, "status" => "done"}),
        "nested" => %{"deep" => %{"deeper" => %{"value" => 42}}},
        "mixed" => [1, "two", true, nil, 3.14]
      }

      conn =
        conn
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => large_data,
          "version" => 0
        })

      body = json_response(conn, 200)
      assert body["state"]["state_data"]["nested"]["deep"]["deeper"]["value"] == 42
      assert length(body["state"]["state_data"]["epics"]) == 50
    end
  end

  describe "GET /api/v1/orchestrator/state/:project_id" do
    test "retrieves state with default state_key=main", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "main",
        state_data: %{"epic" => 5},
        version: 10
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}")

      body = json_response(conn, 200)
      assert body["state"]["state_data"] == %{"epic" => 5}
      assert body["state"]["version"] == 10
      assert body["state"]["state_key"] == "main"
    end

    test "retrieves state with explicit state_key param", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant.id,
        project_id: project.id,
        state_key: "backup",
        state_data: %{"epic" => 4},
        version: 8
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}?state_key=backup")

      body = json_response(conn, 200)
      assert body["state"]["state_data"] == %{"epic" => 4}
      assert body["state"]["version"] == 8
    end

    test "returns 404 when no state exists", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}")

      assert json_response(conn, 404)
    end

    test "returns 403 for agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}")

      assert json_response(conn, 403)
    end

    test "returns 403 for user role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}")

      assert json_response(conn, 403)
    end

    test "tenant isolation: cross-tenant returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {raw_key_b, _api_key} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: agent_b.id})

      fixture(:orchestrator_state, %{
        tenant_id: tenant_a.id,
        project_id: project_a.id,
        state_key: "main"
      })

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> get("/api/v1/orchestrator/state/#{project_a.id}")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/orchestrator/state/:project_id/history" do
    test "returns history after multiple saves", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      # Save state 3 times via the API
      for {version, step} <- [{0, 1}, {1, 2}, {2, 3}] do
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"step" => step},
          "version" => version
        })
      end

      resp =
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history")

      body = json_response(resp, 200)
      assert body["meta"]["total_count"] == 3
      assert length(body["data"]) == 3

      # Most recent first
      [h3, h2, h1] = body["data"]
      assert h3["version"] == 3
      assert h2["version"] == 2
      assert h1["version"] == 1
    end

    test "filters by state_key", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      # Save to "main" twice
      for {version, step} <- [{0, 1}, {1, 2}] do
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"step" => step},
          "version" => version
        })
      end

      # Save to "backup" once
      conn
      |> recycle()
      |> auth_conn(raw_key)
      |> put("/api/v1/orchestrator/state/#{project.id}", %{
        "state_key" => "backup",
        "state_data" => %{"b" => 1},
        "version" => 0
      })

      # Query main history
      resp =
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history?state_key=main")

      body = json_response(resp, 200)
      assert body["meta"]["total_count"] == 2

      # Query backup history
      resp2 =
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history?state_key=backup")

      body2 = json_response(resp2, 200)
      assert body2["meta"]["total_count"] == 1
    end

    test "supports pagination", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      # Save state 5 times
      for {version, step} <- [{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}] do
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> put("/api/v1/orchestrator/state/#{project.id}", %{
          "state_key" => "main",
          "state_data" => %{"step" => step},
          "version" => version
        })
      end

      resp =
        conn
        |> recycle()
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history?page=1&page_size=2")

      body = json_response(resp, 200)
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 2
      assert length(body["data"]) == 2
    end

    test "returns empty list when no state has been saved", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "returns 403 for agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history")

      assert json_response(conn, 403)
    end

    test "returns 403 for user role", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {raw_key, _api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history")

      assert json_response(conn, 403)
    end

    test "tenant isolation: cross-tenant returns 404", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {raw_key_b, _api_key} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> get("/api/v1/orchestrator/state/#{project_a.id}/history")

      assert json_response(conn, 404)
    end

    test "defaults state_key to 'main' when not provided", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      # Save to "main"
      conn
      |> auth_conn(raw_key)
      |> put("/api/v1/orchestrator/state/#{project.id}", %{
        "state_key" => "main",
        "state_data" => %{"main_data" => true},
        "version" => 0
      })

      # Save to "other"
      build_conn()
      |> auth_conn(raw_key)
      |> put("/api/v1/orchestrator/state/#{project.id}", %{
        "state_key" => "other",
        "state_data" => %{"other_data" => true},
        "version" => 0
      })

      # History without state_key should default to "main"
      resp =
        build_conn()
        |> auth_conn(raw_key)
        |> get("/api/v1/orchestrator/state/#{project.id}/history")

      body = json_response(resp, 200)
      assert length(body["data"]) == 1
      assert Enum.at(body["data"], 0)["state_data"] == %{"main_data" => true}
    end
  end
end
