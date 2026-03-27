defmodule Loopctl.Progress.AutoResetTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Progress

  defp setup_reported_story(tenant_settings \\ %{}) do
    tenant = fixture(:tenant, %{settings: tenant_settings})
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    orch_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done
      })

    # Set assigned agent and timestamps
    story =
      story
      |> Ecto.Changeset.change(%{
        assigned_agent_id: impl_agent.id,
        assigned_at: ~U[2026-03-25 10:00:00.000000Z],
        reported_done_at: ~U[2026-03-25 12:00:00.000000Z]
      })
      |> Loopctl.AdminRepo.update!()

    %{
      tenant: tenant,
      epic: epic,
      impl_agent: impl_agent,
      orch_agent: orch_agent,
      story: story
    }
  end

  describe "auto-reset on rejection (default: enabled)" do
    test "rejection triggers auto-reset when setting is true" do
      %{tenant: tenant, story: story, orch_agent: orch_agent, impl_agent: impl_agent} =
        setup_reported_story(%{"auto_reset_on_rejection" => true})

      assert {:ok, updated} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Missing tests"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.verified_status == :rejected
      assert updated.agent_status == :pending
      assert updated.assigned_agent_id == nil
      assert updated.assigned_at == nil
      assert updated.reported_done_at == nil

      # Verify two audit log entries: rejected + auto_reset
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", entity_id: story.id)

      actions = Enum.map(result.data, & &1.action)
      assert "rejected" in actions
      assert "auto_reset" in actions

      # Check auto_reset has actor_type=system
      auto_reset_entry = Enum.find(result.data, &(&1.action == "auto_reset"))
      assert auto_reset_entry.actor_type == "system"
      assert auto_reset_entry.old_state["assigned_agent_id"] == impl_agent.id
      assert auto_reset_entry.new_state["agent_status"] == "pending"
    end

    test "rejection triggers auto-reset by default (empty settings)" do
      %{tenant: tenant, story: story, orch_agent: orch_agent} =
        setup_reported_story(%{})

      assert {:ok, updated} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Incomplete"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.agent_status == :pending
      assert updated.assigned_agent_id == nil
    end

    test "rejection does NOT auto-reset when setting is false" do
      %{tenant: tenant, story: story, orch_agent: orch_agent, impl_agent: impl_agent} =
        setup_reported_story(%{"auto_reset_on_rejection" => false})

      assert {:ok, updated} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Incomplete"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.verified_status == :rejected
      assert updated.agent_status == :reported_done
      assert updated.assigned_agent_id == impl_agent.id

      # Only one audit entry (rejected, no auto_reset)
      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id, entity_type: "story", entity_id: story.id)

      actions = Enum.map(result.data, & &1.action)
      assert "rejected" in actions
      refute "auto_reset" in actions
    end

    test "auto-reset clears reported_done_at" do
      %{tenant: tenant, story: story, orch_agent: orch_agent} =
        setup_reported_story(%{"auto_reset_on_rejection" => true})

      assert story.reported_done_at != nil

      assert {:ok, updated} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Bad code"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.reported_done_at == nil
    end
  end

  describe "atomicity" do
    test "entire rejection + auto-reset is atomic" do
      # If we reject successfully, both rejection and auto-reset should succeed
      %{tenant: tenant, story: story, orch_agent: orch_agent} =
        setup_reported_story(%{"auto_reset_on_rejection" => true})

      assert {:ok, updated} =
               Progress.reject_story(tenant.id, story.id, %{"reason" => "Missing files"},
                 orchestrator_agent_id: orch_agent.id
               )

      assert updated.verified_status == :rejected
      assert updated.agent_status == :pending
    end
  end

  describe "tenant isolation" do
    test "cross-tenant rejection returns not_found" do
      %{story: story} = setup_reported_story()
      tenant_b = fixture(:tenant)
      orch_b = fixture(:agent, %{tenant_id: tenant_b.id, agent_type: :orchestrator})

      assert {:error, :not_found} =
               Progress.reject_story(tenant_b.id, story.id, %{"reason" => "test"},
                 orchestrator_agent_id: orch_b.id
               )
    end
  end
end
