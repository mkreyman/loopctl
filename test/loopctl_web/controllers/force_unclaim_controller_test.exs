defmodule LoopctlWeb.ForceUnclaimControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_story_with_orchestrator(story_attrs) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {orch_key, _} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

    story =
      fixture(:story, Map.merge(%{tenant_id: tenant.id, epic_id: epic.id}, story_attrs))

    # If story has agent_status != pending, set assigned_agent
    story =
      if story.agent_status != :pending do
        story
        |> Ecto.Changeset.change(%{
          assigned_agent_id: impl_agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()
      else
        story
      end

    %{
      tenant: tenant,
      epic: epic,
      impl_agent: impl_agent,
      orch_agent: orch_agent,
      orch_key: orch_key,
      story: story
    }
  end

  describe "POST /api/v1/stories/:id/force-unclaim" do
    test "force-unclaims an implementing story", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant} =
        setup_story_with_orchestrator(%{agent_status: :implementing})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
      assert body["story"]["assigned_agent_id"] == nil
      assert body["story"]["assigned_at"] == nil

      # Check audit log
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "story",
          entity_id: story.id,
          action: "force_unclaimed"
        )

      assert result.data != []
    end

    test "force-unclaim on pending story is idempotent (200)", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_story_with_orchestrator(%{agent_status: :pending})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
    end

    test "force-unclaim preserves verified_status", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_story_with_orchestrator(%{
          agent_status: :reported_done,
          verified_status: :verified
        })

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
      assert body["story"]["verified_status"] == "verified"
    end

    test "force-unclaim works from assigned state", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_story_with_orchestrator(%{agent_status: :assigned})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
    end

    test "force-unclaim works from reported_done state", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_story_with_orchestrator(%{agent_status: :reported_done})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 200)
      assert body["story"]["agent_status"] == "pending"
    end
  end

  describe "role enforcement" do
    test "agent role cannot force-unclaim (403)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :assigned
        })

      impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {agent_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      assert json_response(conn, 403)
    end
  end

  describe "tenant isolation" do
    test "cross-tenant force-unclaim returns 404", %{conn: conn} do
      %{story: story} = setup_story_with_orchestrator(%{agent_status: :assigned})

      # Different tenant
      tenant_b = fixture(:tenant)
      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {orch_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: orch_b.id})

      conn =
        conn
        |> auth_conn(orch_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      assert json_response(conn, 404)
    end
  end
end
