defmodule LoopctlWeb.StoryVerificationControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Artifacts.VerificationResult

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_reported_story(opts \\ %{}) do
    tenant = fixture(:tenant, Map.get(opts, :tenant_attrs, %{}))
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {orch_key, orch_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

    story_attrs =
      Map.merge(
        %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done,
          verified_status: Map.get(opts, :verified_status, :unverified)
        },
        Map.get(opts, :story_attrs, %{})
      )

    story = fixture(:story, story_attrs)

    # Set assigned_agent_id for realism
    story =
      story
      |> Ecto.Changeset.change(%{assigned_agent_id: impl_agent.id})
      |> Loopctl.AdminRepo.update!()

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      impl_agent: impl_agent,
      orch_agent: orch_agent,
      orch_api_key: orch_api_key,
      orch_key: orch_key,
      story: story
    }
  end

  # --- Verify tests ---

  describe "POST /api/v1/stories/:id/verify" do
    test "verifies a reported_done story", %{conn: conn} do
      %{story: story, orch_key: orch_key, orch_agent: orch_agent} = setup_reported_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All artifacts present, tests pass",
          "findings" => %{"tests_run" => 12, "tests_passed" => 12},
          "review_type" => "enhanced_review"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "verified"
      assert body["story"]["verified_at"] != nil

      # Check verification_result was created
      results =
        Loopctl.AdminRepo.all(from(v in VerificationResult, where: v.story_id == ^story.id))

      assert [result] = results
      assert result.result == :pass
      assert result.summary == "All artifacts present, tests pass"
      assert result.review_type == "enhanced_review"
      assert result.orchestrator_agent_id == orch_agent.id
    end

    test "rejects verify on non-reported_done story (409)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :implementing
        })

      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "test"})

      assert json_response(conn, 409)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant} = setup_reported_story()

      conn
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "Looks good"})

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "story",
          entity_id: story.id,
          action: "verified"
        )

      assert result.data != []
      audit = hd(result.data)
      assert audit.old_state["verified_status"] == "unverified"
      assert audit.new_state["verified_status"] == "verified"
    end
  end

  # --- Reject tests ---

  describe "POST /api/v1/stories/:id/reject" do
    test "rejects a reported_done story", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{
          "reason" => "Missing migration file",
          "findings" => %{"missing_artifacts" => ["migration"]},
          "review_type" => "artifact_check"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "rejected"
      assert body["story"]["rejected_at"] != nil
      assert body["story"]["rejection_reason"] == "Missing migration file"

      # Check verification_result was created
      results =
        Loopctl.AdminRepo.all(from(v in VerificationResult, where: v.story_id == ^story.id))

      assert [result] = results
      assert result.result == :fail
      assert result.summary == "Missing migration file"
    end

    test "rejects without reason returns 422", %{conn: _conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      # Missing reason
      conn1 =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{})

      assert json_response(conn1, 422)

      # Empty reason
      conn2 =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => ""})

      assert json_response(conn2, 422)

      # Whitespace-only reason
      conn3 =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "   "})

      assert json_response(conn3, 422)
    end

    test "re-rejects a previously verified story", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_reported_story(%{verified_status: :verified})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{
          "reason" => "Found regression after initial verification"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "rejected"
    end
  end

  # --- Role enforcement tests ---

  describe "role enforcement" do
    test "agent role cannot verify or reject (403)", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_reported_story()

      impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {agent_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

      verify_conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "test"})

      assert json_response(verify_conn, 403)

      reject_conn =
        build_conn()
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "test"})

      assert json_response(reject_conn, 403)
    end

    test "user role cannot verify or reject (403)", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_reported_story()
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      verify_conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "test"})

      assert json_response(verify_conn, 403)

      reject_conn =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "test"})

      assert json_response(reject_conn, 403)
    end
  end

  # --- Tenant isolation tests ---

  describe "tenant isolation" do
    test "cross-tenant verification returns 404", %{conn: conn} do
      %{story: story} = setup_reported_story()

      # Different tenant
      tenant_b = fixture(:tenant)
      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {orch_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: orch_b.id})

      verify_conn =
        conn
        |> auth_conn(orch_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "test"})

      assert json_response(verify_conn, 404)

      reject_conn =
        build_conn()
        |> auth_conn(orch_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "test"})

      assert json_response(reject_conn, 404)
    end
  end

  # --- Verifications list test ---

  describe "GET /api/v1/stories/:story_id/verifications" do
    test "lists verification results for a story", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      # Create a verification
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "Pass"})

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      assert [result] = body["data"]
      assert result["result"] == "pass"
      assert result["summary"] == "Pass"
    end
  end

  # --- Concurrent verify race condition test ---

  describe "concurrent verify race condition" do
    @tag :capture_log
    test "only one orchestrator wins the verification", %{conn: _conn} do
      %{story: story, tenant: tenant} = setup_reported_story()

      orch_1 = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})
      orch_2 = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {key_1, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_1.id})

      {key_2, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_2.id})

      parent = self()

      task_1 =
        Task.async(fn ->
          Sandbox.allow(Loopctl.Repo, parent, self())
          Sandbox.allow(Loopctl.AdminRepo, parent, self())

          build_conn()
          |> auth_conn(key_1)
          |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "pass-1"})
        end)

      task_2 =
        Task.async(fn ->
          Sandbox.allow(Loopctl.Repo, parent, self())
          Sandbox.allow(Loopctl.AdminRepo, parent, self())

          build_conn()
          |> auth_conn(key_2)
          |> post(~p"/api/v1/stories/#{story.id}/verify", %{"summary" => "pass-2"})
        end)

      result_1 = Task.await(task_1, 10_000)
      result_2 = Task.await(task_2, 10_000)

      statuses = Enum.sort([result_1.status, result_2.status])

      # One succeeds, the other gets 409 (already verified, not reported_done anymore)
      assert statuses == [200, 409]
    end
  end
end
