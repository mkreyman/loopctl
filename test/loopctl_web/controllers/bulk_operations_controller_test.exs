defmodule LoopctlWeb.BulkOperationsControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Story

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "POST /api/v1/stories/bulk/claim" do
    test "bulk claim succeeds for multiple ready stories", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})
      s3 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/claim", %{
          "story_ids" => [s1.id, s2.id, s3.id]
        })

      body = json_response(conn, 200)
      results = body["results"]

      assert length(results) == 3
      assert Enum.all?(results, &(&1["status"] == "success"))

      # All stories now assigned
      for id <- [s1.id, s2.id, s3.id] do
        story = AdminRepo.get!(Story, id)
        assert story.agent_status == :assigned
        assert story.assigned_agent_id == agent.id
      end

      # Audit logs created
      audit_count =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "status_changed")
        |> AdminRepo.aggregate(:count, :id)

      assert audit_count == 3
    end

    test "partial success when one story fails precondition", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})
      # story2 is already assigned -- should fail
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :assigned})
      s3 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/claim", %{
          "story_ids" => [s1.id, s2.id, s3.id]
        })

      body = json_response(conn, 200)
      results = body["results"]

      success_count = Enum.count(results, &(&1["status"] == "success"))
      error_count = Enum.count(results, &(&1["status"] == "error"))

      assert success_count == 2
      assert error_count == 1

      # s1 and s3 are now assigned
      assert AdminRepo.get!(Story, s1.id).agent_status == :assigned
      assert AdminRepo.get!(Story, s3.id).agent_status == :assigned
      # s2 remains assigned with original agent (unchanged)
      assert AdminRepo.get!(Story, s2.id).agent_status == :assigned
    end

    test "bulk claim respects story dependency constraints", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :contracted})

      # s2 depends on s1 (s1 not verified yet)
      fixture(:story_dependency, %{
        tenant_id: tenant.id,
        story_id: s2.id,
        depends_on_story_id: s1.id
      })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/claim", %{
          "story_ids" => [s1.id, s2.id]
        })

      body = json_response(conn, 200)
      results = body["results"]

      # s1 should succeed, s2 should fail due to unverified dependency
      s1_result = Enum.find(results, &(&1["story_id"] == s1.id))
      s2_result = Enum.find(results, &(&1["story_id"] == s2.id))

      assert s1_result["status"] == "success"
      assert s2_result["status"] == "error"
      assert s2_result["reason"] =~ "unverified dependency"
    end

    test "cross-tenant isolation -- cannot claim other tenant's stories", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id})

      {raw_key_a, _} =
        fixture(:api_key, %{tenant_id: tenant_a.id, role: :agent, agent_id: agent_a.id})

      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})

      s_b =
        fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id, agent_status: :contracted})

      conn =
        conn
        |> auth_conn(raw_key_a)
        |> post(~p"/api/v1/stories/bulk/claim", %{
          "story_ids" => [s_b.id]
        })

      # All stories failed -> 422
      body = json_response(conn, 422)
      result = hd(body["results"])
      assert result["status"] == "error"
      assert result["reason"] =~ "not found"
    end
  end

  describe "POST /api/v1/stories/bulk/verify" do
    test "bulk verify succeeds for multiple reported_done stories", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orchestrator = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: orchestrator.id
        })

      s1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      s2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/verify", %{
          "stories" => [
            %{"story_id" => s1.id, "result" => "pass", "summary" => "All checks pass"},
            %{"story_id" => s2.id, "result" => "pass", "summary" => "Verified"}
          ]
        })

      body = json_response(conn, 200)
      assert Enum.all?(body["results"], &(&1["status"] == "success"))

      # Both stories are now verified
      assert AdminRepo.get!(Story, s1.id).verified_status == :verified
      assert AdminRepo.get!(Story, s2.id).verified_status == :verified
    end

    test "bulk verify rejects request from agent role", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/verify", %{
          "stories" => [
            %{"story_id" => Ecto.UUID.generate(), "result" => "pass", "summary" => "ok"}
          ]
        })

      assert json_response(conn, 403)
    end

    test "bulk verify fires webhook events per story", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orchestrator = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      fixture(:webhook, %{
        tenant_id: tenant.id,
        events: ["story.verified"],
        active: true
      })

      {raw_key, _api_key} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: orchestrator.id
        })

      s1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      s2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/verify", %{
          "stories" => [
            %{"story_id" => s1.id, "result" => "pass", "summary" => "ok"},
            %{"story_id" => s2.id, "result" => "pass", "summary" => "ok"}
          ]
        })

      assert json_response(conn, 200)

      events =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant.id and e.event_type == "story.verified")
        |> AdminRepo.all()

      assert length(events) == 2
    end
  end

  describe "POST /api/v1/stories/bulk/reject" do
    test "bulk reject succeeds and auto-resets agent_status", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orchestrator = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: orchestrator.id
        })

      s1 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      s2 =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/reject", %{
          "stories" => [
            %{"story_id" => s1.id, "reason" => "Missing tests", "findings" => %{}},
            %{"story_id" => s2.id, "reason" => "No migration", "findings" => %{}}
          ]
        })

      body = json_response(conn, 200)
      assert Enum.all?(body["results"], &(&1["status"] == "success"))

      # Both stories have verified_status=rejected and agent_status reset to pending
      for id <- [s1.id, s2.id] do
        story = AdminRepo.get!(Story, id)
        assert story.verified_status == :rejected
        assert story.agent_status == :pending
        assert is_binary(story.rejection_reason)
      end
    end

    test "bulk reject with missing reason returns validation error", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orchestrator = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {raw_key, _api_key} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: orchestrator.id
        })

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done
        })

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/reject", %{
          "stories" => [
            %{"story_id" => story.id, "reason" => "", "findings" => %{}}
          ]
        })

      body = json_response(conn, 422)
      result = hd(body["results"])
      assert result["status"] == "error"
      assert result["reason"] =~ "reason"
    end
  end

  describe "orchestrator key without agent_id" do
    test "bulk verify returns 400 when orchestrator key has no agent_id", %{conn: conn} do
      tenant = fixture(:tenant)

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/verify", %{
          "stories" => [
            %{"story_id" => Ecto.UUID.generate(), "result" => "pass", "summary" => "ok"}
          ]
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must be linked to a registered agent"
    end

    test "bulk reject returns 400 when orchestrator key has no agent_id", %{conn: conn} do
      tenant = fixture(:tenant)

      {raw_key, _api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/reject", %{
          "stories" => [
            %{"story_id" => Ecto.UUID.generate(), "reason" => "test"}
          ]
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must be linked to a registered agent"
    end
  end
end
