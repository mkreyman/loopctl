defmodule LoopctlWeb.ArtifactReportControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_story_with_keys do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {agent_key, agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

    {orch_key, orch_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done
      })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      impl_agent: impl_agent,
      orch_agent: orch_agent,
      agent_key: agent_key,
      agent_api_key: agent_api_key,
      orch_key: orch_key,
      orch_api_key: orch_api_key,
      story: story
    }
  end

  # --- Create tests ---

  describe "POST /api/v1/stories/:id/artifacts" do
    test "agent creates an artifact report", %{conn: conn} do
      %{story: story, agent_key: agent_key, impl_agent: impl_agent} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "migration",
          "path" => "priv/repo/migrations/20240101_create_users.exs",
          "exists" => true,
          "details" => %{"lines" => 50}
        })

      body = json_response(conn, 201)
      report = body["artifact_report"]

      assert report["artifact_type"] == "migration"
      assert report["path"] == "priv/repo/migrations/20240101_create_users.exs"
      assert report["exists"] == true
      assert report["details"] == %{"lines" => 50}
      assert report["reported_by"] == "agent"
      assert report["reporter_agent_id"] == impl_agent.id
      assert report["story_id"] == story.id
    end

    test "orchestrator creates an artifact report", %{conn: conn} do
      %{story: story, orch_key: orch_key, orch_agent: orch_agent} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "commit_diff",
          "path" => "abc123",
          "exists" => true
        })

      body = json_response(conn, 201)
      report = body["artifact_report"]

      assert report["artifact_type"] == "commit_diff"
      assert report["reported_by"] == "orchestrator"
      assert report["reporter_agent_id"] == orch_agent.id
    end

    test "requires artifact_type (422)", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "path" => "lib/test.ex"
        })

      assert json_response(conn, 422)
    end

    test "nonexistent story returns 404", %{conn: conn} do
      %{agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{Ecto.UUID.generate()}/artifacts", %{
          "artifact_type" => "schema"
        })

      assert json_response(conn, 404)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant} = setup_story_with_keys()

      conn
      |> auth_conn(agent_key)
      |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
        "artifact_type" => "schema",
        "path" => "lib/test.ex"
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "artifact_report",
          action: "created"
        )

      assert result.data != []
      audit = hd(result.data)
      assert audit.new_state["artifact_type"] == "schema"
      assert audit.new_state["story_id"] == story.id
    end

    test "requires path (422)", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "schema"
        })

      assert json_response(conn, 422)
    end

    test "exists defaults to true when not provided", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "schema",
          "path" => "lib/schema.ex"
        })

      body = json_response(conn, 201)
      assert body["artifact_report"]["exists"] == true
    end

    test "exists can be set to false", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "migration",
          "path" => "priv/repo/migrations/001.exs",
          "exists" => false
        })

      body = json_response(conn, 201)
      assert body["artifact_report"]["exists"] == false
    end
  end

  # --- Index tests ---

  describe "GET /api/v1/stories/:id/artifacts" do
    test "lists artifact reports for a story", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant, impl_agent: impl_agent} =
        setup_story_with_keys()

      # Create some reports
      for type <- ~w(schema migration test) do
        Loopctl.Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => type, "path" => "lib/#{type}.ex"},
          agent_id: impl_agent.id,
          reported_by: :agent
        )
      end

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/artifacts")

      body = json_response(conn, 200)
      assert length(body["data"]) == 3
      assert body["meta"]["total_count"] == 3
      assert body["meta"]["page"] == 1
    end

    test "returns empty list for story with no reports", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/artifacts")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "supports pagination", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant, impl_agent: impl_agent} =
        setup_story_with_keys()

      for type <- ~w(schema migration test route context) do
        Loopctl.Artifacts.create_artifact_report(
          tenant.id,
          story.id,
          %{"artifact_type" => type, "path" => "lib/#{type}.ex"},
          agent_id: impl_agent.id,
          reported_by: :agent
        )
      end

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/artifacts?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["total_pages"] == 3
    end

    test "nonexistent story returns 404", %{conn: conn} do
      %{agent_key: agent_key} = setup_story_with_keys()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{Ecto.UUID.generate()}/artifacts")

      assert json_response(conn, 404)
    end
  end

  # --- Role enforcement ---

  describe "role enforcement" do
    test "user role cannot create artifact reports (403)", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_story_with_keys()
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "schema"
        })

      assert json_response(conn, 403)
    end

    test "user role can list artifact reports (user >= agent in hierarchy)", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_story_with_keys()
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> get(~p"/api/v1/stories/#{story.id}/artifacts")

      assert json_response(conn, 200)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "cross-tenant artifact creation returns 404", %{conn: conn} do
      %{story: story} = setup_story_with_keys()

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :implementer})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> post(~p"/api/v1/stories/#{story.id}/artifacts", %{
          "artifact_type" => "schema"
        })

      assert json_response(conn, 404)
    end

    test "cross-tenant artifact listing returns 404", %{conn: conn} do
      %{story: story} = setup_story_with_keys()

      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :implementer})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/stories/#{story.id}/artifacts")

      assert json_response(conn, 404)
    end
  end
end
