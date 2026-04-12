defmodule LoopctlWeb.StoryVerificationControllerTest do
  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Progress

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

    # Set assigned_agent_id and reported_done_at for realism
    story =
      story
      |> Ecto.Changeset.change(%{
        assigned_agent_id: impl_agent.id,
        reported_done_at: DateTime.utc_now()
      })
      |> Loopctl.AdminRepo.update!()

    ctx = %{
      tenant: tenant,
      project: project,
      epic: epic,
      impl_agent: impl_agent,
      orch_agent: orch_agent,
      orch_api_key: orch_api_key,
      orch_key: orch_key,
      story: story
    }

    # Optionally create a review_record (default: true for most tests)
    if Map.get(opts, :with_review_record, true) do
      {:ok, _} =
        Progress.record_review(
          tenant.id,
          story.id,
          %{"review_type" => "enhanced", "summary" => "Review passed"},
          reviewer_agent_id: orch_agent.id
        )
    end

    ctx
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

    test "verifies with result=partial", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "Partial pass - minor issues remain",
          "result" => "partial",
          "review_type" => "enhanced_review"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "verified"

      # Check verification_result has result=partial
      results =
        Loopctl.AdminRepo.all(from(v in VerificationResult, where: v.story_id == ^story.id))

      assert [result] = results
      assert result.result == :partial
      assert result.summary == "Partial pass - minor issues remain"
    end

    test "defaults result to pass when not provided", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All good",
          "review_type" => "enhanced"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "verified"

      results =
        Loopctl.AdminRepo.all(from(v in VerificationResult, where: v.story_id == ^story.id))

      assert [result] = results
      assert result.result == :pass
    end

    test "rejects verify when no review_record exists (422)", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_reported_story(%{with_review_record: false})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All good"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "No review record found"
      assert body["error"]["message"] =~ "review-complete"
    end

    test "succeeds when review_record exists (review_type and summary are now optional)", %{
      conn: conn
    } do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      # review_type and summary are now optional on the verify endpoint
      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{})

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "verified"
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
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "test",
          "review_type" => "enhanced"
        })

      assert json_response(conn, 409)
    end

    test "creates audit log entry", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant} = setup_reported_story()

      conn
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{
        "summary" => "Looks good",
        "review_type" => "enhanced"
      })

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
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "test",
          "review_type" => "enhanced"
        })

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
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "test",
          "review_type" => "enhanced"
        })

      assert json_response(verify_conn, 403)

      reject_conn =
        build_conn()
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "test"})

      assert json_response(reject_conn, 403)
    end
  end

  # --- Self-verify block tests ---

  describe "self-verify block" do
    test "same agent cannot verify their own implementation (409)", %{conn: conn} do
      %{story: story, tenant: tenant, impl_agent: impl_agent} = setup_reported_story()

      # Create an orchestrator key linked to the SAME agent that implemented
      {self_orch_key, _} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: impl_agent.id
        })

      conn =
        conn
        |> auth_conn(self_orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "Looks good",
          "review_type" => "enhanced"
        })

      body = json_response(conn, 409)
      assert body["error"]["message"] =~ "Cannot verify your own implementation"
    end

    test "same agent cannot reject their own implementation (409)", %{conn: conn} do
      %{story: story, tenant: tenant, impl_agent: impl_agent} = setup_reported_story()

      {self_orch_key, _} =
        fixture(:api_key, %{
          tenant_id: tenant.id,
          role: :orchestrator,
          agent_id: impl_agent.id
        })

      conn =
        conn
        |> auth_conn(self_orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "Bad code"})

      body = json_response(conn, 409)
      assert body["error"]["message"] =~ "Cannot verify your own implementation"
    end

    test "different agent can verify (200)", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_reported_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All good",
          "review_type" => "enhanced"
        })

      assert json_response(conn, 200)["story"]["verified_status"] == "verified"
    end
  end

  # --- Nil agent_id guard tests ---

  describe "orchestrator key without agent_id" do
    defp setup_unlinked_orchestrator_key(tenant) do
      {orch_key, _orch_api_key} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      orch_key
    end

    test "verify returns 400 when orchestrator key has no agent_id", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_reported_story()
      orch_key = setup_unlinked_orchestrator_key(tenant)

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "test",
          "review_type" => "enhanced"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must be linked to a registered agent"
    end

    test "reject returns 400 when orchestrator key has no agent_id", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_reported_story()
      orch_key = setup_unlinked_orchestrator_key(tenant)

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/reject", %{"reason" => "test"})

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must be linked to a registered agent"
    end

    test "force_unclaim returns 400 when orchestrator key has no agent_id", %{conn: conn} do
      %{story: story, tenant: tenant} = setup_reported_story()
      orch_key = setup_unlinked_orchestrator_key(tenant)

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/force-unclaim")

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "must be linked to a registered agent"
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
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "test",
          "review_type" => "enhanced"
        })

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

      # Create a verification (review_record already created by setup_reported_story)
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

  # --- Issue 8: descriptive 409 errors ---

  describe "descriptive 409 responses" do
    test "verify on pending story returns 409 with current state", %{conn: conn} do
      %{orch_key: orch_key, epic: epic, tenant: tenant} = setup_reported_story()

      pending_story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{pending_story.id}/verify", %{
          "summary" => "Looks good",
          "review_type" => "enhanced"
        })

      body = json_response(conn, 409)
      assert body["error"]["context"]["current_agent_status"] == "pending"
      assert body["error"]["context"]["attempted_action"] == "verify"
      assert body["error"]["message"] =~ "Cannot verify"
    end

    test "reject on pending story returns 409 with current state", %{conn: conn} do
      %{orch_key: orch_key, epic: epic, tenant: tenant} = setup_reported_story()

      pending_story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{pending_story.id}/reject", %{
          "reason" => "Bad work"
        })

      body = json_response(conn, 409)
      assert body["error"]["context"]["current_agent_status"] == "pending"
      assert body["error"]["context"]["attempted_action"] == "reject"
    end
  end

  # --- Issue 11: verify-all endpoint ---

  describe "POST /api/v1/epics/:id/verify-all" do
    test "verifies all reported_done unverified stories in an epic when review_records exist", %{
      conn: conn
    } do
      %{
        tenant: tenant,
        epic: epic,
        impl_agent: impl_agent,
        orch_key: orch_key,
        orch_agent: orch_agent
      } =
        setup_reported_story()

      # Create 2 more reported_done stories in the same epic, each with a review_record
      for _ <- 1..2 do
        story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

        story =
          story
          |> Ecto.Changeset.change(%{
            agent_status: :reported_done,
            assigned_agent_id: impl_agent.id,
            reported_done_at: DateTime.utc_now()
          })
          |> Loopctl.AdminRepo.update!()

        {:ok, _} =
          Progress.record_review(
            tenant.id,
            story.id,
            %{"review_type" => "enhanced", "summary" => "Passed"},
            reviewer_agent_id: orch_agent.id
          )
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/epics/#{epic.id}/verify-all", %{
          "summary" => "All stories pass review"
        })

      body = json_response(conn, 200)
      assert body["verified_count"] == 3
      assert body["skipped_count"] == 0
      assert body["total_eligible"] == 3
      assert body["errors"] == []
    end

    test "returns zero counts when no stories are eligible", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      # No reported_done stories
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/epics/#{epic.id}/verify-all", %{
          "summary" => "Nothing to verify"
        })

      body = json_response(conn, 200)
      assert body["verified_count"] == 0
      assert body["total_eligible"] == 0
    end

    test "reports skipped stories when no review_records exist", %{conn: conn} do
      %{tenant: tenant, epic: epic, impl_agent: impl_agent, orch_key: orch_key} =
        setup_reported_story(%{with_review_record: false})

      # Add a second reported_done story without a review_record
      story2 = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      story2
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        assigned_agent_id: impl_agent.id,
        reported_done_at: DateTime.utc_now()
      })
      |> Loopctl.AdminRepo.update!()

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/epics/#{epic.id}/verify-all", %{
          "summary" => "All good"
        })

      body = json_response(conn, 200)
      assert body["verified_count"] == 0
      assert body["total_eligible"] == 2
      # Both stories skipped because they have no review_records
      assert body["skipped_count"] == 2
    end

    test "requires orchestrator role (403 for agent)", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      {agent_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{agent_key}")
        |> post(~p"/api/v1/epics/#{epic.id}/verify-all", %{
          "summary" => "All good"
        })

      assert conn.status == 403
    end
  end

  # --- review-complete endpoint tests ---

  describe "POST /api/v1/stories/:id/review-complete" do
    test "orchestrator can record review completion (201)", %{conn: conn} do
      %{story: story, orch_key: orch_key} =
        setup_reported_story(%{with_review_record: false})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced",
          "findings_count" => 5,
          "fixes_count" => 5,
          "summary" => "Enhanced review completed. All findings fixed."
        })

      body = json_response(conn, 201)
      assert body["review_record"]["review_type"] == "enhanced"
      assert body["review_record"]["findings_count"] == 5
      assert body["review_record"]["fixes_count"] == 5
      assert body["review_record"]["story_id"] == story.id
    end

    test "user role can record review completion (201)", %{conn: conn} do
      %{tenant: tenant, story: story} = setup_reported_story(%{with_review_record: false})
      {user_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

      conn =
        conn
        |> auth_conn(user_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "team"
        })

      assert json_response(conn, 201)
    end

    test "agent role cannot record review completion (403)", %{conn: conn} do
      %{tenant: tenant, story: story, impl_agent: impl_agent} =
        setup_reported_story(%{with_review_record: false})

      {agent_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

      conn =
        conn
        |> auth_conn(agent_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced"
        })

      assert json_response(conn, 403)
    end

    test "returns 422 when story is not reported_done", %{conn: conn} do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {orch_key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

      # Pending story
      pending_story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{pending_story.id}/review-complete", %{
          "review_type" => "enhanced"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] =~ "reported_done"
    end

    test "returns 404 for unknown story", %{conn: conn} do
      %{orch_key: orch_key} = setup_reported_story(%{with_review_record: false})

      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{Ecto.UUID.generate()}/review-complete", %{
          "review_type" => "enhanced"
        })

      assert json_response(conn, 404)
    end

    test "verify succeeds after review-complete", %{conn: conn} do
      %{story: story, orch_key: orch_key, orch_agent: orch_agent} =
        setup_reported_story(%{with_review_record: false})

      # Step 1: Call review-complete
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
        "review_type" => "enhanced",
        "findings_count" => 3,
        "fixes_count" => 3,
        "summary" => "Three issues found and fixed."
      })
      |> json_response(201)

      # Step 2: Verify succeeds
      conn =
        conn
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All good"
        })

      body = json_response(conn, 200)
      assert body["story"]["verified_status"] == "verified"

      # Verify a verification_result was created
      results =
        Loopctl.AdminRepo.all(from(v in VerificationResult, where: v.story_id == ^story.id))

      assert [result] = results
      assert result.result == :pass
      assert result.orchestrator_agent_id == orch_agent.id
    end

    test "tenant isolation: cannot record review for another tenant's story", %{conn: conn} do
      %{story: story} = setup_reported_story(%{with_review_record: false})

      tenant_b = fixture(:tenant)
      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {orch_key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: orch_b.id})

      conn =
        conn
        |> auth_conn(orch_key_b)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced"
        })

      assert json_response(conn, 404)
    end
  end
end
