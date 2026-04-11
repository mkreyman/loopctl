defmodule LoopctlWeb.ReviewRecordControllerTest do
  @moduledoc """
  Tests for the explicit-reviewer-identity invariant on
  POST /api/v1/stories/:id/review-complete.

  These tests lock in the fix for the chain-of-custody bypass discovered
  during the Epic 25 orchestration run: a user-role key with a nil
  agent_id was able to record a review without ever triggering the
  self-review check, because Progress.validate_not_self_review/2 had
  a nil short-circuit that returned :ok.

  The controller now requires an attributable reviewer agent id from
  one of two sources: the `reviewer_agent_id` body param, or the
  caller's own api_key.agent_id. If neither is available, the request
  is rejected with 422.
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # Mirrors story_verification_controller_test.exs's :setup_reported_story
  # shape (tenant, project, epic, implementer agent, story in reported_done
  # with assigned_agent_id set to the implementer).
  defp setup_reported_done_story(_ctx \\ %{}) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done
      })

    story =
      story
      |> Ecto.Changeset.change(%{
        assigned_agent_id: impl_agent.id,
        reported_done_at: DateTime.utc_now()
      })
      |> Loopctl.AdminRepo.update!()

    %{tenant: tenant, project: project, epic: epic, impl_agent: impl_agent, story: story}
  end

  describe "POST /stories/:id/review-complete — explicit reviewer identity" do
    test "rejects user-role key with no agent_id when reviewer_agent_id is not in body",
         %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      # User-role key without agent_id — this is the attack vector.
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "manual",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "reviewer_agent_id is required"
    end

    test "accepts user-role key with nil agent_id when reviewer_agent_id in body is a valid tenant agent different from implementer",
         %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      reviewer_agent =
        fixture(:agent, %{tenant_id: tenant.id, name: "human-reviewer"})

      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "manual",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0,
          "reviewer_agent_id" => reviewer_agent.id
        })

      body = json_response(conn, 201)
      assert body["review_record"]["reviewer_agent_id"] == reviewer_agent.id
      assert body["review_record"]["story_id"] == story.id
    end

    test "rejects when declared reviewer_agent_id matches the story's assigned_agent_id (self_review_blocked)",
         %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      # Pass the implementer's own agent_id as the reviewer.
      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "manual",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0,
          "reviewer_agent_id" => story.assigned_agent_id
        })

      # self_review_blocked maps to 409 in the fallback controller.
      body = json_response(conn, 409)
      assert body["error"]["message"] =~ "Cannot review your own implementation"
    end

    test "rejects when body reviewer_agent_id belongs to another tenant", %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      other_tenant = fixture(:tenant)

      other_agent =
        fixture(:agent, %{tenant_id: other_tenant.id, name: "cross-tenant-reviewer"})

      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "manual",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0,
          "reviewer_agent_id" => other_agent.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "not found in tenant"
    end

    test "rejects user-role key when body reviewer_agent_id equals the caller's own agent_id",
         %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      # A user-role key that also happens to be bound to an agent.
      caller_agent = fixture(:agent, %{tenant_id: tenant.id, name: "caller-agent"})

      {user_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :user, agent_id: caller_agent.id})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "manual",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0,
          "reviewer_agent_id" => caller_agent.id
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "must not match the caller's own agent_id"
    end

    test "orchestrator-role key with its own agent_id works without body reviewer_agent_id (backward compat)",
         %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_done_story()

      orch_agent = fixture(:agent, %{tenant_id: tenant.id, name: "orch-reviewer"})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced",
          "findings_count" => 0,
          "fixes_count" => 0,
          "disproved_count" => 0
        })

      body = json_response(conn, 201)
      assert body["review_record"]["reviewer_agent_id"] == orch_agent.id
    end
  end
end
