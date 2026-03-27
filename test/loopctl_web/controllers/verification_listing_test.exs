defmodule LoopctlWeb.VerificationListingTest do
  @moduledoc """
  Tests for US-8.2: Verification results listing with iteration tracking.

  Covers:
  - Paginated GET /stories/:story_id/verifications
  - iteration field (1-indexed, auto-computed)
  - GET /stories/:id includes iteration_count and artifacts
  - result enum: pass/fail/partial
  - review_type field
  - Tenant isolation
  """

  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp setup_verified_story do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {agent_key, _agent_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

    {orch_key, _orch_api_key} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done
      })

    # Set assigned agent for realism
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
      agent_key: agent_key,
      orch_key: orch_key,
      story: story
    }
  end

  # --- Paginated verification listing ---

  describe "GET /api/v1/stories/:story_id/verifications (paginated)" do
    test "returns paginated verification results", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant, orch_agent: orch_agent} =
        setup_verified_story()

      # Create multiple verification results via fixtures
      for i <- 1..5 do
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch_agent.id,
          result: if(rem(i, 2) == 0, do: :pass, else: :fail),
          iteration: i,
          review_type: "enhanced_review"
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications?page=1&page_size=2")

      body = json_response(conn, 200)
      assert length(body["data"]) == 2
      assert body["meta"]["total_count"] == 5
      assert body["meta"]["page"] == 1
      assert body["meta"]["page_size"] == 2
      assert body["meta"]["total_pages"] == 3
    end

    test "returns all results without pagination params", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant, orch_agent: orch_agent} =
        setup_verified_story()

      fixture(:verification_result, %{
        tenant_id: tenant.id,
        story_id: story.id,
        orchestrator_agent_id: orch_agent.id,
        result: :pass,
        iteration: 1
      })

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert body["meta"]["total_count"] == 1
      assert body["meta"]["page"] == 1
    end

    test "returns empty list for story with no verifications", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_verified_story()

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["total_count"] == 0
    end

    test "results are ordered by inserted_at descending (newest first)", %{conn: conn} do
      %{story: story, orch_key: orch_key, tenant: tenant, orch_agent: orch_agent} =
        setup_verified_story()

      # Insert sequentially so inserted_at increases
      for i <- [1, 2, 3] do
        fixture(:verification_result, %{
          tenant_id: tenant.id,
          story_id: story.id,
          orchestrator_agent_id: orch_agent.id,
          result: :pass,
          iteration: i,
          summary: "Iteration #{i}"
        })
      end

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      iterations = Enum.map(body["data"], & &1["iteration"])
      assert iterations == [3, 2, 1]
    end
  end

  # --- Iteration auto-computation ---

  describe "iteration field auto-computation" do
    test "verify creates verification result with correct iteration number", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_verified_story()

      # First verification
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{
        "summary" => "First pass",
        "review_type" => "artifact_check"
      })

      # Need to re-reject to get story back to a verifiable state for second verify
      # Re-reject
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/reject", %{
        "reason" => "Regression found"
      })

      # Advance story back to reported_done for second verify
      story_now = Loopctl.AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id)

      story_now
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        verified_status: :unverified
      })
      |> Loopctl.AdminRepo.update!()

      # Second verification
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{
        "summary" => "Second pass"
      })

      # Check iterations
      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      iterations = Enum.map(body["data"], & &1["iteration"])
      # verify(1) -> reject(2) -> verify(3) = 3 results, newest first
      assert iterations == [3, 2, 1]
    end
  end

  # --- Verification result fields ---

  describe "verification result fields" do
    test "result enum includes pass, fail values", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_verified_story()

      # Verify (pass)
      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/verify", %{
        "summary" => "All good",
        "findings" => %{"tests_run" => 12},
        "review_type" => "enhanced_review"
      })

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      [result] = body["data"]
      assert result["result"] == "pass"
      assert result["summary"] == "All good"
      assert result["findings"] == %{"tests_run" => 12}
      assert result["review_type"] == "enhanced_review"
      assert result["iteration"] == 1
      assert result["story_id"] == story.id
    end

    test "rejection creates fail result with review_type", %{conn: conn} do
      %{story: story, orch_key: orch_key} = setup_verified_story()

      build_conn()
      |> auth_conn(orch_key)
      |> post(~p"/api/v1/stories/#{story.id}/reject", %{
        "reason" => "Missing migration",
        "findings" => %{"missing" => ["migration"]},
        "review_type" => "artifact_check"
      })

      conn =
        conn
        |> auth_conn(orch_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      body = json_response(conn, 200)
      [result] = body["data"]
      assert result["result"] == "fail"
      assert result["summary"] == "Missing migration"
      assert result["review_type"] == "artifact_check"
    end
  end

  # --- Story show includes iteration_count ---

  describe "GET /api/v1/stories/:id includes iteration_count" do
    test "iteration_count reflects number of verification results", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant, orch_agent: orch_agent} =
        setup_verified_story()

      # No verifications yet
      conn1 =
        build_conn()
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}")

      body1 = json_response(conn1, 200)
      assert body1["story"]["iteration_count"] == 0

      # Add 2 verification results
      fixture(:verification_result, %{
        tenant_id: tenant.id,
        story_id: story.id,
        orchestrator_agent_id: orch_agent.id,
        iteration: 1,
        result: :fail
      })

      fixture(:verification_result, %{
        tenant_id: tenant.id,
        story_id: story.id,
        orchestrator_agent_id: orch_agent.id,
        iteration: 2,
        result: :pass
      })

      conn2 =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}")

      body2 = json_response(conn2, 200)
      assert body2["story"]["iteration_count"] == 2
    end

    test "artifacts are included in story show response", %{conn: conn} do
      %{story: story, agent_key: agent_key, tenant: tenant, impl_agent: impl_agent} =
        setup_verified_story()

      # Create artifact reports
      Loopctl.Artifacts.create_artifact_report(
        tenant.id,
        story.id,
        %{"artifact_type" => "schema", "path" => "lib/test.ex"},
        agent_id: impl_agent.id,
        reported_by: :agent
      )

      Loopctl.Artifacts.create_artifact_report(
        tenant.id,
        story.id,
        %{"artifact_type" => "migration", "path" => "priv/repo/migrations/001.exs"},
        agent_id: impl_agent.id,
        reported_by: :agent
      )

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}")

      body = json_response(conn, 200)
      assert length(body["story"]["artifacts"]) == 2

      artifact_types = Enum.map(body["story"]["artifacts"], & &1["artifact_type"])
      assert "schema" in artifact_types
      assert "migration" in artifact_types
    end
  end

  # --- Role enforcement ---

  describe "role enforcement (verifications listing)" do
    test "agent role gets 403 on verification listing", %{conn: conn} do
      %{story: story, agent_key: agent_key} = setup_verified_story()

      conn =
        conn
        |> auth_conn(agent_key)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      assert json_response(conn, 403)
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation (verifications listing)" do
    test "cross-tenant verification listing returns 404", %{conn: conn} do
      %{story: story} = setup_verified_story()

      tenant_b = fixture(:tenant)
      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      {key_b, _} =
        fixture(:api_key, %{tenant_id: tenant_b.id, role: :orchestrator, agent_id: orch_b.id})

      conn =
        conn
        |> auth_conn(key_b)
        |> get(~p"/api/v1/stories/#{story.id}/verifications")

      assert json_response(conn, 404)
    end
  end
end
