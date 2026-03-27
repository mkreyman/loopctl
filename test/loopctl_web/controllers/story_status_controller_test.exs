defmodule LoopctlWeb.StoryStatusControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_story_with_agent(attrs \\ %{}) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {raw_key, api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

    story_attrs =
      Map.merge(
        %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          title: "Phoenix scaffold",
          acceptance_criteria: [
            %{"id" => "AC-1", "description" => "App boots"},
            %{"id" => "AC-2", "description" => "Tests pass"}
          ]
        },
        attrs
      )

    story = fixture(:story, story_attrs)

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      api_key: api_key,
      raw_key: raw_key,
      story: story
    }
  end

  # --- Contract tests ---

  describe "POST /api/v1/stories/:id/contract" do
    test "contracts a story with correct title and AC count", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 2
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "contracted"
      assert body["story"]["id"] == story.id
    end

    test "rejects with wrong title (422)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Wrong title",
          "ac_count" => 2
        })

      assert json_response(conn, 422)
    end

    test "rejects with wrong AC count (422)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 5
        })

      assert json_response(conn, 422)
    end

    test "rejects contract on non-pending story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} =
        setup_story_with_agent(%{agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => story.title,
          "ac_count" => length(story.acceptance_criteria)
        })

      assert json_response(conn, 409)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, raw_key: raw_key, tenant: tenant} = setup_story_with_agent()

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/stories/#{story.id}/contract", %{
        "story_title" => "Phoenix scaffold",
        "ac_count" => 2
      })

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", entity_id: story.id)

      assert result.data != []
      audit = Enum.find(result.data, &(&1.action == "status_changed"))
      assert audit.old_state["agent_status"] == "pending"
      assert audit.new_state["agent_status"] == "contracted"
    end
  end

  # --- Claim tests ---

  describe "POST /api/v1/stories/:id/claim" do
    test "claims a contracted story", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} =
        setup_story_with_agent(%{agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "assigned"
      assert body["story"]["assigned_agent_id"] == agent.id
      assert body["story"]["assigned_at"] != nil
    end

    test "rejects claim on pending story (must contract first, 409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 409)
    end

    test "rejects claim on already assigned story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} =
        setup_story_with_agent(%{agent_status: :assigned})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 409)
    end
  end

  # --- Start tests ---

  describe "POST /api/v1/stories/:id/start" do
    test "starts an assigned story", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      # Need to put agent into assigned status with correct agent
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "implementing"
    end

    test "cross-tenant start returns 404", %{conn: conn} do
      %{story: story, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Agent from a completely different tenant
      %{raw_key: other_raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 404)
    end

    test "rejects start on non-assigned story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 409)
    end

    test "wrong agent on same tenant gets 403", %{conn: conn} do
      %{story: story, tenant: tenant, agent: agent} = setup_story_with_agent()

      # Assign story to original agent
      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Create a second agent in same tenant
      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 403)
    end
  end

  # --- Report tests ---

  describe "POST /api/v1/stories/:id/report" do
    test "reports an implementing story as done", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"
      assert body["story"]["reported_done_at"] != nil
    end

    test "reports with optional artifact", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report", %{
          "artifact" => %{
            "artifact_type" => "commit_diff",
            "path" => "abc123",
            "exists" => true,
            "details" => %{"files_changed" => 5}
          }
        })

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "reported_done"

      # Verify artifact was created
      artifacts =
        Loopctl.AdminRepo.all(
          from(a in Loopctl.Artifacts.ArtifactReport, where: a.story_id == ^story.id)
        )

      assert length(artifacts) == 1
      artifact = hd(artifacts)
      assert artifact.artifact_type == "commit_diff"
      assert artifact.path == "abc123"
      assert artifact.exists == true
      assert artifact.details == %{"files_changed" => 5}
      assert artifact.reported_by == :agent
      assert artifact.reporter_agent_id == agent.id
    end

    test "rejects report by wrong agent (403)", %{conn: conn} do
      %{story: story, tenant: tenant, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      assert json_response(conn, 403)
    end
  end

  # --- Unclaim tests ---

  describe "POST /api/v1/stories/:id/unclaim" do
    test "unclaims an implementing story back to pending", %{conn: conn} do
      %{story: story, raw_key: raw_key, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
      assert body["story"]["assigned_agent_id"] == nil
      assert body["story"]["assigned_at"] == nil
    end

    test "rejects unclaim on pending story (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      assert json_response(conn, 409)
    end

    test "wrong agent cannot unclaim (403)", %{conn: conn} do
      %{story: story, tenant: tenant, agent: agent} = setup_story_with_agent()

      story =
        story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {other_raw_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: other_agent.id})

      conn =
        conn
        |> auth_conn(other_raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/unclaim")

      assert json_response(conn, 403)
    end
  end

  # --- Full lifecycle test ---

  describe "full agent lifecycle" do
    test "contract -> claim -> start -> report", %{conn: _conn} do
      %{story: story, raw_key: raw_key, agent: agent, tenant: tenant} =
        setup_story_with_agent()

      # Contract
      conn1 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Phoenix scaffold",
          "ac_count" => 2
        })

      assert json_response(conn1, 200)["story"]["agent_status"] == "contracted"

      # Claim
      conn2 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      body2 = json_response(conn2, 200)
      assert body2["story"]["agent_status"] == "assigned"
      assert body2["story"]["assigned_agent_id"] == agent.id
      assert body2["story"]["assigned_at"] != nil

      # Start
      conn3 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn3, 200)["story"]["agent_status"] == "implementing"

      # Report
      conn4 =
        build_conn()
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body4 = json_response(conn4, 200)
      assert body4["story"]["agent_status"] == "reported_done"
      assert body4["story"]["reported_done_at"] != nil

      # Verify 4 audit log entries with action=status_changed
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "story",
          entity_id: story.id,
          action: "status_changed"
        )

      assert length(result.data) == 4
    end
  end

  # --- Role enforcement tests ---

  describe "role enforcement" do
    test "orchestrator role cannot use agent endpoints (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      for action <- ["contract", "claim", "start", "report", "unclaim"] do
        resp =
          conn
          |> auth_conn(orch_key)
          |> post("/api/v1/stories/#{story.id}/#{action}")

        assert resp.status == 403, "#{action} should require agent role, got #{resp.status}"
      end
    end

    test "user role cannot use agent endpoints (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      for action <- ["contract", "claim", "start", "report", "unclaim"] do
        resp =
          conn
          |> auth_conn(user_key)
          |> post("/api/v1/stories/#{story.id}/#{action}")

        assert resp.status == 403, "#{action} should require agent role, got #{resp.status}"
      end
    end
  end

  # --- Tenant isolation tests ---

  describe "tenant isolation" do
    test "cross-tenant access returns 404", %{conn: conn} do
      # Tenant A with story
      tenant_a = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_a.id})
      epic = fixture(:epic, %{tenant_id: tenant_a.id, project_id: project.id})

      story =
        fixture(:story, %{tenant_id: tenant_a.id, epic_id: epic.id, agent_status: :contracted})

      # Tenant B with agent
      tenant_b = fixture(:tenant)
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :implementer})

      {raw_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :agent, agent_id: agent_b.id})

      conn =
        conn
        |> auth_conn(raw_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      assert json_response(conn, 404)
    end
  end

  # --- Invalid transition tests ---

  describe "invalid state transitions" do
    test "cannot start from pending (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(conn, 409)
    end

    test "cannot report from pending (409)", %{conn: conn} do
      %{story: story, raw_key: raw_key} = setup_story_with_agent()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      assert json_response(conn, 409)
    end

    test "nonexistent story returns 404", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/#{Ecto.UUID.generate()}/claim")

      assert json_response(conn, 404)
    end
  end

  # --- Concurrent claim race condition test ---

  describe "concurrent claim race condition" do
    @tag :capture_log
    test "only one agent wins the claim", %{conn: _conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story =
        fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

      agent_a = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      agent_b = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {raw_key_a, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent_a.id})

      {raw_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent_b.id})

      # Allow sandbox access for spawned tasks
      parent = self()

      task_a =
        Task.async(fn ->
          Sandbox.allow(Loopctl.Repo, parent, self())
          Sandbox.allow(Loopctl.AdminRepo, parent, self())

          build_conn()
          |> auth_conn(raw_key_a)
          |> post(~p"/api/v1/stories/#{story.id}/claim")
        end)

      task_b =
        Task.async(fn ->
          Sandbox.allow(Loopctl.Repo, parent, self())
          Sandbox.allow(Loopctl.AdminRepo, parent, self())

          build_conn()
          |> auth_conn(raw_key_b)
          |> post(~p"/api/v1/stories/#{story.id}/claim")
        end)

      result_a = Task.await(task_a, 10_000)
      result_b = Task.await(task_b, 10_000)

      statuses = Enum.sort([result_a.status, result_b.status])

      # Exactly one 200 and one 409
      assert statuses == [200, 409]
    end
  end
end
