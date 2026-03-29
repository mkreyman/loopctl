defmodule LoopctlWeb.UiTestControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_project_with_keys do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    {user_key, _user_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    %{
      tenant: tenant,
      project: project,
      agent: agent,
      agent_key: agent_key,
      user_key: user_key
    }
  end

  # --- POST /api/v1/projects/:project_id/ui-tests ---

  describe "POST /api/v1/projects/:project_id/ui-tests" do
    test "agent starts a UI test run", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests", %{
          "guide_reference" => "docs/guides/checkout_flow.md"
        })

      body = json_response(conn, 201)
      run = body["ui_test_run"]

      assert run["status"] == "in_progress"
      assert run["guide_reference"] == "docs/guides/checkout_flow.md"
      assert run["project_id"] == project.id
      assert run["findings"] == []
      assert run["findings_count"] == 0
      assert run["completed_at"] == nil
    end

    test "returns 422 when guide_reference is missing", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests", %{})

      assert json_response(conn, 422)
    end

    test "user role can start a run (meets minimum agent level)", %{conn: conn} do
      %{project: project, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests", %{
          "guide_reference" => "docs/guides/test.md"
        })

      # user role (level 3) exceeds agent role (level 1) in the hierarchy
      assert json_response(conn, 201)
    end

    test "requires authentication", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      conn = post(conn, ~p"/api/v1/projects/#{project.id}/ui-tests", %{})
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/projects/:project_id/ui-tests ---

  describe "GET /api/v1/projects/:project_id/ui-tests" do
    test "lists runs for a project", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()

      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})
      fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests")

      body = json_response(conn, 200)

      assert body["meta"]["total"] == 2
      assert length(body["data"]) == 2
    end

    test "filters by status", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()

      fixture(:ui_test_run, %{
        tenant_id: tenant.id,
        project_id: project.id,
        status: :passed
      })

      fixture(:ui_test_run, %{
        tenant_id: tenant.id,
        project_id: project.id,
        status: :failed
      })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests?status=passed")

      body = json_response(conn, 200)
      assert body["meta"]["total"] == 1
      assert Enum.all?(body["data"], &(&1["status"] == "passed"))
    end

    test "respects limit and offset pagination", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()

      Enum.each(1..4, fn _ ->
        fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})
      end)

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests?limit=2&offset=0")

      body = json_response(conn, 200)
      assert body["meta"]["total"] == 4
      assert length(body["data"]) == 2
      assert body["meta"]["limit"] == 2
      assert body["meta"]["offset"] == 0
    end

    test "returns empty list for project with no runs", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests")

      body = json_response(conn, 200)
      assert body["meta"]["total"] == 0
      assert body["data"] == []
    end

    test "user role can list runs (meets minimum agent level)", %{conn: conn} do
      %{project: project, user_key: user_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(user_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests")

      # user role (level 3) exceeds agent role (level 1) in the hierarchy
      body = json_response(conn, 200)
      assert body["data"] == []
    end
  end

  # --- GET /api/v1/projects/:project_id/ui-tests/:id ---

  describe "GET /api/v1/projects/:project_id/ui-tests/:id" do
    test "returns a single run with findings", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}")

      body = json_response(conn, 200)
      assert body["ui_test_run"]["id"] == run.id
      assert body["ui_test_run"]["guide_reference"] == run.guide_reference
    end

    test "returns 404 when run does not exist", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end

    test "returns 404 for another tenant's run", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      other_tenant = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other_tenant.id})

      other_run =
        fixture(:ui_test_run, %{
          tenant_id: other_tenant.id,
          project_id: other_project.id
        })

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/projects/#{project.id}/ui-tests/#{other_run.id}")

      assert json_response(conn, 404)
    end
  end

  # --- POST /api/v1/projects/:project_id/ui-tests/:id/findings ---

  describe "POST /api/v1/projects/:project_id/ui-tests/:id/findings" do
    test "adds a finding to a run", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/findings", %{
          "step" => "3. Add to cart",
          "severity" => "critical",
          "type" => "crash",
          "description" => "Crashes on add to cart",
          "screenshot_path" => "screenshots/crash.png"
        })

      body = json_response(conn, 200)
      updated = body["ui_test_run"]

      assert updated["findings_count"] == 1
      assert updated["critical_count"] == 1
      assert updated["screenshots_count"] == 1
      assert length(updated["findings"]) == 1

      finding = List.first(updated["findings"])
      assert finding["step"] == "3. Add to cart"
      assert finding["severity"] == "critical"
    end

    test "returns 422 when run is already completed", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()

      run =
        fixture(:ui_test_run, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :passed
        })

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/findings", %{
          "description" => "Too late"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "not in progress"
    end

    test "returns 404 when run does not exist", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(
          ~p"/api/v1/projects/#{project.id}/ui-tests/#{Ecto.UUID.generate()}/findings",
          %{"description" => "test"}
        )

      assert json_response(conn, 404)
    end
  end

  # --- POST /api/v1/projects/:project_id/ui-tests/:id/complete ---

  describe "POST /api/v1/projects/:project_id/ui-tests/:id/complete" do
    test "completes a run with passed status", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/complete", %{
          "status" => "passed",
          "summary" => "All 8 flows passed without issues."
        })

      body = json_response(conn, 200)
      completed = body["ui_test_run"]

      assert completed["status"] == "passed"
      assert completed["summary"] == "All 8 flows passed without issues."
      assert completed["completed_at"] != nil
    end

    test "completes a run with failed status", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/complete", %{
          "status" => "failed",
          "summary" => "3 critical issues found."
        })

      body = json_response(conn, 200)
      assert body["ui_test_run"]["status"] == "failed"
    end

    test "returns 422 when run is already completed", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()

      run =
        fixture(:ui_test_run, %{
          tenant_id: tenant.id,
          project_id: project.id,
          status: :passed
        })

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/complete", %{
          "status" => "failed",
          "summary" => "Already done"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "already completed"
    end

    test "returns 422 when summary is missing", %{conn: conn} do
      %{tenant: tenant, project: project, agent_key: agent_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/complete", %{
          "status" => "passed"
        })

      assert json_response(conn, 422)
    end

    test "returns 404 when run does not exist", %{conn: conn} do
      %{project: project, agent_key: agent_key} = setup_project_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(
          ~p"/api/v1/projects/#{project.id}/ui-tests/#{Ecto.UUID.generate()}/complete",
          %{"status" => "passed", "summary" => "summary"}
        )

      assert json_response(conn, 404)
    end

    test "user role can complete a run (meets minimum agent level)", %{conn: conn} do
      %{tenant: tenant, project: project, user_key: user_key} = setup_project_with_keys()
      run = fixture(:ui_test_run, %{tenant_id: tenant.id, project_id: project.id})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/projects/#{project.id}/ui-tests/#{run.id}/complete", %{
          "status" => "passed",
          "summary" => "summary"
        })

      # user role (level 3) exceeds agent role (level 1) in the hierarchy
      assert json_response(conn, 200)
    end
  end
end
