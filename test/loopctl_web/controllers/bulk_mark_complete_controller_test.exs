defmodule LoopctlWeb.BulkMarkCompleteControllerTest do
  @moduledoc """
  Tests for POST /api/v1/stories/bulk/mark-complete (Issue 5).
  """
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit.AuditLog
  alias Loopctl.WorkBreakdown.Story

  import Ecto.Query

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp orchestrator_key(tenant_id) do
    agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator})
    fixture(:api_key, %{tenant_id: tenant_id, role: :orchestrator, agent_id: agent.id})
  end

  describe "POST /api/v1/stories/bulk/mark-complete" do
    test "marks stories as reported_done + verified in one step", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      {raw_key, _} = orchestrator_key(tenant.id)

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :pending})
      s2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, agent_status: :implementing})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{
          "stories" => [
            %{
              "story_id" => s1.id,
              "summary" => "Pre-existing on master",
              "review_type" => "pre_existing"
            },
            %{"story_id" => s2.id, "summary" => "Pre-existing", "review_type" => "pre_existing"}
          ]
        })

      body = json_response(conn, 200)
      results = body["results"]

      assert length(results) == 2
      assert Enum.all?(results, &(&1["status"] == "success"))

      # Both stories should be reported_done AND verified
      for id <- [s1.id, s2.id] do
        story = AdminRepo.get!(Story, id)
        assert story.agent_status == :reported_done
        assert story.verified_status == :verified
        assert story.reported_done_at != nil
        assert story.verified_at != nil
      end
    end

    test "creates audit log entries for each story", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      {raw_key, _} = orchestrator_key(tenant.id)

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/stories/bulk/mark-complete", %{
        "stories" => [
          %{"story_id" => s1.id, "summary" => "Pre-existing", "review_type" => "pre_existing"}
        ]
      })

      audit_count =
        AuditLog
        |> where([a], a.tenant_id == ^tenant.id and a.action == "mark_complete")
        |> AdminRepo.aggregate(:count, :id)

      assert audit_count == 1
    end

    test "creates verification result records", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      {raw_key, _} = orchestrator_key(tenant.id)

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn
      |> auth_conn(raw_key)
      |> post(~p"/api/v1/stories/bulk/mark-complete", %{
        "stories" => [
          %{
            "story_id" => s1.id,
            "summary" => "Pre-existing on master",
            "review_type" => "pre_existing"
          }
        ]
      })

      vr =
        VerificationResult
        |> where([v], v.story_id == ^s1.id)
        |> AdminRepo.one()

      assert vr != nil
      assert vr.result == :pass
      assert vr.review_type == "pre_existing"
      assert vr.summary == "Pre-existing on master"
    end

    test "partial success when a story is not found", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      {raw_key, _} = orchestrator_key(tenant.id)

      s1 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      bad_id = uuid()

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{
          "stories" => [
            %{"story_id" => s1.id, "summary" => "Exists"},
            %{"story_id" => bad_id, "summary" => "Does not exist"}
          ]
        })

      body = json_response(conn, 200)
      results = body["results"]

      success = Enum.find(results, &(&1["story_id"] == s1.id))
      failure = Enum.find(results, &(&1["story_id"] == bad_id))

      assert success["status"] == "success"
      assert failure["status"] == "error"
      assert failure["reason"] =~ "not found"
    end

    test "returns 422 when stories list is empty", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = orchestrator_key(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{"stories" => []})

      assert json_response(conn, 422)
    end

    test "returns 422 when stories param is missing", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = orchestrator_key(tenant.id)

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{})

      assert json_response(conn, 422)
    end

    test "requires orchestrator role — agent is rejected", %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{
          "stories" => [%{"story_id" => uuid(), "summary" => "x"}]
        })

      assert json_response(conn, 403)
    end

    test "requires orchestrator role — user is rejected", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{
          "stories" => [%{"story_id" => uuid(), "summary" => "x"}]
        })

      assert json_response(conn, 403)
    end

    test "returns 400 when orchestrator key is not linked to an agent", %{conn: conn} do
      tenant = fixture(:tenant)
      # orchestrator key with no agent_id
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn =
        conn
        |> auth_conn(raw_key)
        |> post(~p"/api/v1/stories/bulk/mark-complete", %{
          "stories" => [%{"story_id" => uuid(), "summary" => "x"}]
        })

      # validate_orchestrator_agent_linked returns bad_request
      json_response(conn, 400)
    end

    test "cross-tenant isolation: cannot mark another tenant's stories", %{conn: conn} do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id, epic_id: epic_b.id})

      {raw_key_a, _} = orchestrator_key(tenant_a.id)

      conn
      |> auth_conn(raw_key_a)
      |> post(~p"/api/v1/stories/bulk/mark-complete", %{
        "stories" => [%{"story_id" => story_b.id, "summary" => "tenant cross"}]
      })

      # Story B should still be untouched
      story_b_after = AdminRepo.get!(Story, story_b.id)
      assert story_b_after.agent_status == :pending
      assert story_b_after.verified_status == :unverified
    end
  end
end
