defmodule Loopctl.ProgressTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

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

    test "rejects with wrong ac_count" do
      %{tenant: tenant, story: story, agent: agent} = setup_story()

      assert {:error, :ac_count_mismatch} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => "Build API",
                   "ac_count" => 99
                 },
                 agent_id: agent.id
               )
    end

    test "rejects transition from non-pending state" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :contracted})

      assert {:error, :invalid_transition} =
               Progress.contract_story(
                 tenant.id,
                 story.id,
                 %{
                   "story_title" => story.title,
                   "ac_count" => length(story.acceptance_criteria)
                 },
                 agent_id: agent.id
               )
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

      assert {:error, :invalid_transition} =
               Progress.claim_story(tenant.id, story.id, agent_id: agent.id)
    end

    test "rejects from assigned (already claimed)" do
      %{tenant: tenant, story: story, agent: agent} =
        setup_story(%{agent_status: :assigned})

      assert {:error, :invalid_transition} =
               Progress.claim_story(tenant.id, story.id, agent_id: agent.id)
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
    test "transitions implementing -> reported_done" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing,
          assigned_agent_id: agent.id,
          assigned_at: DateTime.utc_now()
        })
        |> Loopctl.AdminRepo.update!()

      assert {:ok, updated} =
               Progress.report_story(tenant.id, story.id, agent_id: agent.id)

      assert updated.agent_status == :reported_done
      assert updated.reported_done_at != nil
    end

    test "creates artifact report when provided" do
      %{tenant: tenant, agent: agent} = ctx = setup_story()

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
               Progress.report_story(tenant.id, story.id, [agent_id: agent.id], artifact)

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

  describe "tenant isolation" do
    test "tenant A cannot access tenant B stories" do
      %{story: story} = setup_story()
      tenant_b = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.claim_story(tenant_b.id, story.id, agent_id: Ecto.UUID.generate())
    end
  end
end
