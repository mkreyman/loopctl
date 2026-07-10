defmodule Loopctl.E2E.CustodyLifecycleJourneyTest do
  @moduledoc """
  End-to-end journey for the full story chain-of-custody lifecycle.

  Excluded from the default suite (`@moduletag :e2e`); run with `mix test.e2e`
  or `mix test --only e2e`. Drives a story through the ENTIRE lifecycle over the
  real HTTP controllers — contract → claim → start → request-review → report →
  review-complete → verify — and asserts the chain-of-custody 409s fire when the
  same agent tries to report / review / verify its own work
  (self_report_blocked / self_review_blocked / self_verify_blocked).

  Each self-block runs on its OWN tenant: two of those guards halt the tenant on
  violation (custody enforcement working as designed), so isolating them keeps
  the assertions independent.
  """
  use LoopctlWeb.ConnCase, async: true

  @moduletag :e2e

  alias Loopctl.AdminRepo

  setup :verify_on_exit!

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # A pending story with two ACs, an implementer agent+key, and a distinct
  # orchestrator agent+key (used for the cross-agent report/review/verify steps).
  defp lifecycle_ctx do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {impl_key, _} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: impl_agent.id})

    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {orch_key, _} =
      fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: orch_agent.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        title: "Custody journey story",
        acceptance_criteria: [
          %{"id" => "AC-1", "description" => "It works"},
          %{"id" => "AC-2", "description" => "Tests pass"}
        ]
      })

    %{
      tenant: tenant,
      impl_agent: impl_agent,
      impl_key: impl_key,
      orch_agent: orch_agent,
      orch_key: orch_key,
      story: story
    }
  end

  describe "full custody lifecycle" do
    test "contract -> claim -> start -> request-review -> report -> review-complete -> verify",
         %{conn: _conn} do
      ctx = lifecycle_ctx()
      %{story: story, impl_key: impl_key, orch_key: orch_key, impl_agent: impl_agent} = ctx

      # Contract (implementer)
      contract =
        build_conn()
        |> auth_conn(impl_key)
        |> post(~p"/api/v1/stories/#{story.id}/contract", %{
          "story_title" => "Custody journey story",
          "ac_count" => 2
        })

      assert json_response(contract, 200)["story"]["agent_status"] == "contracted"

      # Claim (implementer)
      claim =
        build_conn()
        |> auth_conn(impl_key)
        |> post(~p"/api/v1/stories/#{story.id}/claim")

      claim_body = json_response(claim, 200)
      assert claim_body["story"]["agent_status"] == "assigned"
      assert claim_body["story"]["assigned_agent_id"] == impl_agent.id

      # Start (implementer)
      start =
        build_conn()
        |> auth_conn(impl_key)
        |> post(~p"/api/v1/stories/#{story.id}/start")

      assert json_response(start, 200)["story"]["agent_status"] == "implementing"

      # Request review (implementer signals readiness; status unchanged)
      request_review =
        build_conn()
        |> auth_conn(impl_key)
        |> post(~p"/api/v1/stories/#{story.id}/request-review")

      assert json_response(request_review, 200)["story"]["agent_status"] == "implementing"

      # Report (orchestrator — a DIFFERENT identity than the implementer)
      report =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      report_body = json_response(report, 200)
      assert report_body["story"]["agent_status"] == "reported_done"
      assert report_body["story"]["reported_done_at"] != nil

      # Review complete (orchestrator — independent review record)
      review =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced",
          "summary" => "Reviewed end to end.",
          "findings_count" => 0,
          "fixes_count" => 0
        })

      assert json_response(review, 201)["review_record"]["story_id"] == story.id

      # Verify (orchestrator) — 202 accepted, story flips to verified
      verify =
        build_conn()
        |> auth_conn(orch_key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "All acceptance criteria met.",
          "review_type" => "enhanced_review"
        })

      verify_body = json_response(verify, 202)
      assert verify_body["story"]["verified_status"] == "verified"
      assert verify_body["story"]["verified_at"] != nil
    end
  end

  describe "chain-of-custody self-action blocks" do
    test "self_report_blocked (409): the assigned agent cannot report its own work",
         %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      {key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      story
      |> Ecto.Changeset.change(%{
        agent_status: :implementing,
        assigned_agent_id: agent.id,
        assigned_at: DateTime.utc_now()
      })
      |> AdminRepo.update!()

      resp =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/stories/#{story.id}/report")

      body = json_response(resp, 409)
      assert body["error"]["code"] == "self_report_blocked"
    end

    test "self_review_blocked (409): the assigned agent cannot review its own work",
         %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      # An orchestrator-role key whose agent_id IS the assigned agent — the review
      # endpoint requires orchestrator/user role, and self-review is caught by
      # reviewer_agent_id == assigned_agent_id.
      {key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      # reported_done + assigned_agent_id are enough — self-review keys on
      # reviewer_agent_id == assigned_agent_id, checked before any timestamp logic.
      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done,
          assigned_agent_id: agent.id
        })

      resp =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/stories/#{story.id}/review-complete", %{
          "review_type" => "enhanced",
          "summary" => "Trying to review my own work."
        })

      body = json_response(resp, 409)
      assert body["error"]["status"] == 409
      assert body["error"]["message"] =~ "Cannot review your own implementation"
    end

    test "self_verify_blocked (409): the assigned agent cannot verify its own work",
         %{conn: conn} do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {key, _} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator, agent_id: agent.id})

      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      # self_verify_check is the FIRST step in verify_story's Multi (before the
      # review-record check), so reported_done + assigned_agent_id suffice.
      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: :reported_done,
          assigned_agent_id: agent.id
        })

      resp =
        conn
        |> auth_conn(key)
        |> post(~p"/api/v1/stories/#{story.id}/verify", %{
          "summary" => "Trying to verify my own work.",
          "review_type" => "enhanced_review"
        })

      body = json_response(resp, 409)
      assert body["error"]["code"] == "self_verify_blocked"
    end
  end
end
