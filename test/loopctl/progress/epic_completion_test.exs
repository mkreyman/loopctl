defmodule Loopctl.Progress.EpicCompletionTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Progress

  defp setup_epic_with_stories(story_count, verified_count) do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    stories =
      Enum.map(1..story_count, fn i ->
        verified_status = if i <= verified_count, do: :verified, else: :unverified
        agent_status = if verified_status == :verified, do: :reported_done, else: :reported_done

        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          agent_status: agent_status,
          verified_status: verified_status
        })
      end)

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      orch_agent: orch_agent,
      stories: stories
    }
  end

  describe "epic completion detection" do
    test "fires when last story is verified" do
      %{tenant: tenant, epic: epic, orch_agent: orch_agent, stories: stories} =
        setup_epic_with_stories(2, 1)

      # stories[0] is verified, stories[1] is unverified (reported_done)
      last_story = Enum.at(stories, 1)

      # Ensure reported_done_at is set and create review record
      last_story =
        last_story
        |> Ecto.Changeset.change(%{reported_done_at: DateTime.utc_now()})
        |> Loopctl.AdminRepo.update!()

      assert {:ok, _} =
               Progress.record_review(tenant.id, last_story.id, %{"review_type" => "enhanced"})

      assert {:ok, _updated} =
               Progress.verify_story(
                 tenant.id,
                 last_story.id,
                 %{"summary" => "All good"},
                 orchestrator_agent_id: orch_agent.id
               )

      # Check for epic.completed audit log entry
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", entity_id: epic.id)

      completed_entries = Enum.filter(result.data, &(&1.action == "completed"))
      assert [entry] = completed_entries
      assert entry.new_state["epic_id"] == epic.id
      assert entry.new_state["story_count"] == 2
    end

    test "does not fire when stories remain unverified" do
      %{tenant: tenant, epic: epic, orch_agent: orch_agent, stories: stories} =
        setup_epic_with_stories(3, 0)

      # Verify just one of three
      first_story = Enum.at(stories, 0)

      first_story =
        first_story
        |> Ecto.Changeset.change(%{reported_done_at: DateTime.utc_now()})
        |> Loopctl.AdminRepo.update!()

      assert {:ok, _} =
               Progress.record_review(tenant.id, first_story.id, %{"review_type" => "enhanced"})

      assert {:ok, _updated} =
               Progress.verify_story(
                 tenant.id,
                 first_story.id,
                 %{"summary" => "Partial"},
                 orchestrator_agent_id: orch_agent.id
               )

      # No epic.completed event
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "epic", entity_id: epic.id)

      completed_entries = Enum.filter(result.data, &(&1.action == "completed"))
      assert completed_entries == []
    end

    test "no duplicate epic.completed on re-verification" do
      %{tenant: tenant, epic: epic, orch_agent: orch_agent} =
        setup_epic_with_stories(1, 0)

      [story] =
        Loopctl.AdminRepo.all(
          from(s in Loopctl.WorkBreakdown.Story,
            where: s.epic_id == ^epic.id and s.tenant_id == ^tenant.id
          )
        )

      # Set reported_done_at and create review record for first verify
      story
      |> Ecto.Changeset.change(%{reported_done_at: DateTime.utc_now()})
      |> Loopctl.AdminRepo.update!()

      assert {:ok, _} =
               Progress.record_review(tenant.id, story.id, %{"review_type" => "enhanced"})

      # First verification triggers completion
      assert {:ok, _} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Pass 1"},
                 orchestrator_agent_id: orch_agent.id
               )

      {:ok, result1} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "epic",
          entity_id: epic.id,
          action: "completed"
        )

      assert Enum.count(result1.data) == 1

      # Reject and re-verify
      assert {:ok, _} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Oops"},
                 orchestrator_agent_id: orch_agent.id
               )

      # Re-set to reported_done for re-verification
      story = Loopctl.AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id)

      story
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        verified_status: :unverified,
        reported_done_at: DateTime.utc_now()
      })
      |> Loopctl.AdminRepo.update!()

      # Create another review record for the second verify
      assert {:ok, _} =
               Progress.record_review(tenant.id, story.id, %{"review_type" => "enhanced"})

      assert {:ok, _} =
               Progress.verify_story(
                 tenant.id,
                 story.id,
                 %{"summary" => "Pass 2"},
                 orchestrator_agent_id: orch_agent.id
               )

      # Still only one epic.completed event (idempotent)
      {:ok, result2} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "epic",
          entity_id: epic.id,
          action: "completed"
        )

      # May have 2 here because the second verification fires again.
      # The idempotent check uses existing audit log entries, so it should be 1.
      assert Enum.count(result2.data) == 1
    end

    test "zero-story epic never completes" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

      refute Progress.all_stories_verified?(tenant.id, epic.id)
    end

    test "cross-tenant isolation in completion check" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      epic_a = fixture(:epic, %{tenant_id: tenant_a.id, project_id: project_a.id})

      fixture(:story, %{
        tenant_id: tenant_a.id,
        epic_id: epic_a.id,
        agent_status: :reported_done,
        verified_status: :verified
      })

      # From tenant A's perspective, epic is complete
      assert Progress.all_stories_verified?(tenant_a.id, epic_a.id)

      # From tenant B's perspective, no stories (returns false)
      refute Progress.all_stories_verified?(tenant_b.id, epic_a.id)
    end
  end
end
