defmodule Loopctl.ProgressTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Progress

  defp setup_story(attrs \\ %{}) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    story_attrs =
      Map.merge(
        %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          title: "Build API",
          acceptance_criteria: [
            %{"id" => "AC-1", "description" => "Endpoint works"},
            %{"id" => "AC-2", "description" => "Tests pass"}
          ]
        },
        attrs
      )

    story = fixture(:story, story_attrs)

    %{tenant: tenant, project: project, epic: epic, agent: agent, story: story}
  end

  describe "contract_story/4" do
    test "transitions pending -> contracted with correct title/ac_count" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:ok, updated} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => "Build API",
                   "ac_count" => 2
                 },
                 agent_id: agent.id
               )

      assert updated.agent_status == :contracted
    end

    test "rejects with wrong title" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, :title_mismatch} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => "Wrong",
                   "ac_count" => 2
                 },
                 agent_id: agent.id
               )
    end

    test "rejects with wrong ac_count (returns contract_mismatch with counts)" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, {:contract_mismatch, ctx}} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => "Build API",
                   "ac_count" => 99
                 },
                 agent_id: agent.id
               )

      assert ctx.expected_ac_count == 2
      assert ctx.provided_ac_count == 99
    end

    test "rejects transition from non-pending state (returns invalid_transition context)" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :contracted})

      assert {:error, {:invalid_transition, ctx}} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => story.title,
                   "ac_count" => length(story.acceptance_criteria)
                 },
                 agent_id: agent.id
               )

      assert ctx.current_agent_status == :contracted
      assert ctx.attempted_action == "contract"
    end
  end

  describe "claim_story/3" do
    test "transitions contracted -> assigned" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :contracted})

      assert {:ok, updated} =
               Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      assert updated.agent_status == :assigned
      assert updated.assigned_agent_id == agent.id
      assert updated.assigned_at != nil
    end

    test "rejects from pending (must contract first)" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, :must_contract_first} =
               Progress.claim_story(tenant.id, story.id, agent_id: agent.id)
    end

    test "rejects from assigned (already claimed, returns invalid_transition context)" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :assigned})

      assert {:error, {:invalid_transition, ctx}} =
               Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      assert ctx.current_agent_status == :assigned
      assert ctx.attempted_action == "claim"
    end
  end

  describe "start_story/3" do
    test "transitions assigned -> implementing" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, updated} =
               Progress.start_story(tenant.id, story.id, agent_id: agent.id)

      assert updated.agent_status == :implementing
    end

    test "rejects from wrong agent" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      assert {:error, :not_assigned_agent} =
               Progress.start_story(tenant.id, story.id, agent_id: other_agent.id)
    end
  end

  describe "report_story/4" do
    test "transitions implementing -> reported_done (cross-agent)" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      # A second agent (the reviewer) does the reporting
      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, updated} =
               Progress.report_story(tenant.id, story.id, agent_id: reviewer.id)

      assert updated.agent_status == :reported_done
      assert updated.reported_done_at != nil
      assert updated.reported_by_agent_id == reviewer.id
    end

    test "blocks self-report (assigned agent cannot report their own work)" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, :self_report_blocked} =
               Progress.report_story(tenant.id, story.id, agent_id: agent.id)
    end

    test "returns changeset error when artifact params are invalid" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Missing required 'path' field
      bad_artifact = %{
        "artifact_type" => "migration",
        "exists" => true,
        "details" => %{"lines" => 50}
      }

      assert {:error, %Ecto.Changeset{}} =
               Progress.report_story(
                 tenant.id,
                 story.id,
                 [agent_id: reviewer.id],
                 bad_artifact
               )
    end

    test "creates artifact report when provided" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      artifact = %{
        "artifact_type" => "migration",
        "path" => "priv/repo/migrations/123.exs",
        "exists" => true,
        "details" => %{"lines" => 50}
      }

      assert {:ok, _updated} =
               Progress.report_story(tenant.id, story.id, [agent_id: reviewer.id], artifact)

      reports =
        Loopctl.AdminRepo.all(
          from(a in Loopctl.Artifacts.ArtifactReport, where: a.story_id == ^story.id)
        )

      assert length(reports) == 1
      assert hd(reports).artifact_type == "migration"
    end
  end

  describe "unclaim_story/3" do
    test "resets assigned story to pending" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, updated} =
               Progress.unclaim_story(tenant.id, story.id, agent_id: agent.id)

      assert updated.agent_status == :pending
      assert updated.assigned_agent_id == nil
      assert updated.assigned_at == nil
    end

    test "rejects unclaim on pending story" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, :invalid_transition} =
               Progress.unclaim_story(tenant.id, story.id, agent_id: agent.id)
    end

    test "contracted story cannot be unclaimed by regular agent" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :contracted})

      assert {:error, :not_assigned_to_you} =
               Progress.unclaim_story(tenant.id, story.id, agent_id: agent.id)
    end
  end

  describe "verify_story/4 self-verify block" do
    test "blocks same agent from verifying their own implementation" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      # Set up story as reported_done with agent assigned
      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      # Same agent_id tries to verify
      assert {:error, :self_verify_blocked} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Looks good", "review_type" => "enhanced"},
                 orchestrator_agent_id: agent.id
               )
    end

    test "allows different agent to verify when review_record exists" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Create review_record first
      assert {:ok, _} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => "enhanced", "summary" => "Review passed"}
               )

      assert {:ok, updated} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "All good"},
                 orchestrator_agent_id: other_agent.id
               )

      assert updated.verified_status == :verified
    end
  end

  describe "reject_story/4 self-verify block" do
    test "blocks same agent from rejecting their own implementation" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, :self_verify_blocked} =
               Progress.reject_story(
                 tenant.id,
                 story.id,
                 %{"reason" => "Bad code"},
                 orchestrator_agent_id: agent.id
               )
    end

    test "allows different agent to reject" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:ok, updated} =
               Progress.reject_story(
                 tenant.id,
                 story.id,
                 %{"reason" => "Missing tests"},
                 orchestrator_agent_id: other_agent.id
               )

      assert updated.verified_status == :rejected
    end
  end

  # --- Issue 3: skip_contract_check for orchestrator ---

  describe "contract_story/4 skip_contract_check" do
    test "orchestrator can contract with skip_contract_check: true (no params required)" do
      %{tenant: tenant, story: story} = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:ok, updated} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{},
                 agent_id: orch_agent.id,
                 skip_contract_check: true
               )

      assert updated.agent_status == :contracted
    end

    test "skip_contract_check does not bypass state transition validation" do
      %{tenant: tenant, story: story} = setup_story(%{agent_status: :contracted})
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Even with skip, cannot re-contract an already-contracted story
      assert {:error, {:invalid_transition, ctx}} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{},
                 agent_id: orch_agent.id,
                 skip_contract_check: true
               )

      assert ctx.current_agent_status == :contracted
    end
  end

  # --- Issue 8: descriptive invalid_transition errors ---

  describe "verify_story/4 invalid transition errors" do
    test "returns descriptive error when story is not reported_done" do
      %{tenant: tenant} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Story is pending, not reported_done
      assert {:error, {:invalid_transition, error_ctx}} =
               Progress.verify_story(
                 tenant.id,
                 ctx.story.id,
                 %{"summary" => "Looks good", "review_type" => "enhanced"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert error_ctx.attempted_action == "verify"
      assert error_ctx.current_agent_status == :pending
      assert error_ctx.hint =~ "reported_done"
    end

    test "returns descriptive error when story is already verified" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          verified_status: :verified
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, {:invalid_transition, error_ctx}} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Looks good", "review_type" => "enhanced"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert error_ctx.current_verified_status == :verified
      assert error_ctx.hint =~ "already verified"
    end
  end

  describe "reject_story/4 invalid transition errors" do
    test "returns descriptive error when story is not reportable" do
      %{tenant: tenant} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Story is pending — cannot be rejected
      assert {:error, {:invalid_transition, error_ctx}} =
               Progress.reject_story(
                 tenant.id,
                 ctx.story.id,
                 %{"reason" => "Bad code"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert error_ctx.attempted_action == "reject"
      assert error_ctx.current_agent_status == :pending
      assert error_ctx.hint =~ "reported_done"
    end
  end

  # --- Issue 11: verify_all_in_epic ---

  describe "verify_all_in_epic/4" do
    test "verifies all reported_done unverified stories in an epic when review_records exist" do
      %{tenant: tenant, epic: epic, agent: agent} = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Create 3 more stories in same epic, all reported_done, each with a review_record
      for _ <- 1..3 do
        story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

        story =
          story
          |> Ecto.Changeset.change(%{
            agent_status: :reported_done,
            assigned_agent_id: agent.id,
            reported_done_at: DateTime.utc_now()
          })
          |> Loopctl.AdminRepo.update!()

        # Review record required for each story
        assert {:ok, _} =
                 Progress.record_review(tenant.id, story.id, %{
                   "review_type" => "enhanced",
                   "summary" => "Passed"
                 })
      end

      assert {:ok, result} =
               Progress.verify_all_in_epic(
                 tenant.id,
                 epic.id,
                 %{"summary" => "All pass"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert result.verified_count == 3
      assert result.skipped_count == 0
      assert result.total_eligible == 3
      assert result.errors == []
    end

    test "returns zero counts when no stories are eligible" do
      %{tenant: tenant, epic: epic} = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # The setup_story creates one pending story — not eligible for verify_all

      assert {:ok, result} =
               Progress.verify_all_in_epic(
                 tenant.id,
                 epic.id,
                 %{"summary" => "All pass"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert result.verified_count == 0
      assert result.total_eligible == 0
    end

    test "reports errors for stories without review_records" do
      %{tenant: tenant, epic: epic, agent: agent} = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      # Create a reported_done story WITHOUT a review_record
      story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})

      story
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        assigned_agent_id: agent.id,
        reported_done_at: DateTime.utc_now()
      })
      |> Loopctl.AdminRepo.update!()

      assert {:ok, result} =
               Progress.verify_all_in_epic(
                 tenant.id,
                 epic.id,
                 %{"summary" => "All pass"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert result.verified_count == 0
      assert result.skipped_count == 1
      assert result.total_eligible == 1
      assert length(result.errors) == 1
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot access tenant B stories" do
      %{story: story} = setup_story()
      tenant_b = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.claim_story(tenant_b.id, story.id, agent_id: Ecto.UUID.generate())
    end
  end

  # --- Review Records ---

  describe "record_review/4" do
    test "creates a review_record for a reported_done story" do
      %{tenant: tenant, story: story} =
        setup_story(%{agent_status: :reported_done, reported_done_at: DateTime.utc_now()})

      assert {:ok, review_record} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{
                   "review_type" => "enhanced",
                   "findings_count" => 5,
                   "fixes_count" => 5,
                   "summary" => "Enhanced review completed. All findings fixed."
                 }
               )

      assert review_record.review_type == "enhanced"
      assert review_record.findings_count == 5
      assert review_record.fixes_count == 5
      assert review_record.story_id == story.id
      assert review_record.tenant_id == tenant.id
      assert review_record.completed_at != nil
    end

    test "creates review_record with reviewer_agent_id" do
      %{tenant: tenant, story: story} =
        setup_story(%{agent_status: :reported_done, reported_done_at: DateTime.utc_now()})

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:ok, review_record} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => "team"},
                 reviewer_agent_id: reviewer.id
               )

      assert review_record.reviewer_agent_id == reviewer.id
    end

    test "returns not_found for unknown story" do
      %{tenant: tenant} = setup_story()

      assert {:error, :not_found} =
               Progress.record_review(
                 tenant.id,
                 Ecto.UUID.generate(),
                 %{"review_type" => "enhanced"}
               )
    end

    test "returns story_not_reported_done when story is not in reported_done status" do
      %{tenant: tenant, story: story} = setup_story()

      # Story is in pending status
      assert {:error, :story_not_reported_done} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => "enhanced"}
               )
    end

    test "returns changeset error when review_type is blank" do
      %{tenant: tenant, story: story} =
        setup_story(%{agent_status: :reported_done, reported_done_at: DateTime.utc_now()})

      assert {:error, %Ecto.Changeset{}} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => ""}
               )
    end

    test "blocks self-review when reviewer is the assigned implementer" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, :self_review_blocked} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => "enhanced"},
                 reviewer_agent_id: agent.id
               )
    end

    test "allows cross-agent review" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, review_record} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{"review_type" => "enhanced"},
                 reviewer_agent_id: reviewer.id
               )

      assert review_record.reviewer_agent_id == reviewer.id
    end
  end

  describe "request_review/3" do
    test "succeeds when called by the assigned agent on an implementing story" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, returned_story} =
               Progress.request_review(tenant.id, story.id, agent_id: agent.id)

      assert returned_story.id == story.id
      # Status does NOT change
      assert returned_story.agent_status == :implementing
    end

    test "rejects if caller is not the assigned agent" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      other_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, :not_assigned_agent} =
               Progress.request_review(tenant.id, story.id, agent_id: other_agent.id)
    end

    test "rejects if story is not in implementing status" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :assigned,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, {:invalid_transition, ctx}} =
               Progress.request_review(tenant.id, story.id, agent_id: agent.id)

      assert ctx.attempted_action == "request-review"
    end

    test "returns not_found for unknown story" do
      %{tenant: tenant} = setup_story()

      assert {:error, :not_found} =
               Progress.request_review(tenant.id, Ecto.UUID.generate(),
                 agent_id: Ecto.UUID.generate()
               )
    end
  end

  describe "verify_story/4 review_record enforcement" do
    test "fails with review_not_conducted when no review_record exists" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:error, :review_not_conducted} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Looks good"},
                 orchestrator_agent_id: orch_agent.id
               )
    end

    test "succeeds when review_record exists and is after reported_done_at" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      reported_done_at = ~U[2026-03-30 00:00:00.000000Z]

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: reported_done_at
        })
        |> Loopctl.AdminRepo.update!()

      # Review completed after reported_done_at
      assert {:ok, _} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{
                   "review_type" => "enhanced",
                   "completed_at" => ~U[2026-03-30 01:00:00.000000Z]
                 }
               )

      assert {:ok, updated} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Looks good"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.verified_status == :verified
    end

    test "fails when review_record completed_at is before reported_done_at (stale review)" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()
      orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      reported_done_at = ~U[2026-03-30 02:00:00.000000Z]

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now(),
          reported_done_at: reported_done_at
        })
        |> Loopctl.AdminRepo.update!()

      # Review completed BEFORE reported_done_at (stale)
      {:ok, _} =
        Loopctl.AdminRepo.insert(
          %ReviewRecord{
            tenant_id: tenant.id,
            story_id: story.id
          }
          |> ReviewRecord.create_changeset(%{
            review_type: "enhanced",
            completed_at: ~U[2026-03-30 01:00:00.000000Z]
          })
        )

      assert {:error, :review_not_conducted} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Looks good"},
                 orchestrator_agent_id: orch_agent.id
               )
    end
  end

  describe "review_record tenant isolation" do
    test "tenant A cannot create review_record for tenant B story" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      epic_b = fixture(:epic, %{tenant_id: tenant_b.id, project_id: project_b.id})

      story_b =
        fixture(:story, %{
          tenant_id: tenant_b.id,
          epic_id: epic_b.id,
          agent_status: :reported_done,
          reported_done_at: DateTime.utc_now()
        })

      # Tenant A tries to create review_record for tenant B story
      assert {:error, :not_found} =
               Progress.record_review(
                 tenant_a.id,
                 story_b.id,
                 %{"review_type" => "enhanced"}
               )
    end
  end
end
