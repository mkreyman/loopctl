defmodule Loopctl.Projects.ProjectProgressTest do
  @moduledoc """
  Tests for the project progress summary endpoint (US-5.2).

  NOTE: Story and Epic schemas don't exist yet (Epic 6). All progress
  values are currently zeroed. These tests verify the response shape
  and tenant scoping. When Epic 6 is implemented, additional tests
  with actual story/epic data should be added.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Projects

  describe "get_project_progress/2" do
    test "returns zeroed progress summary for empty project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, progress} = Projects.get_project_progress(tenant.id, project.id)

      # Story counts
      assert progress.total_stories == 0

      # Agent status breakdown
      assert progress.stories_by_agent_status.pending == 0
      assert progress.stories_by_agent_status.contracted == 0
      assert progress.stories_by_agent_status.assigned == 0
      assert progress.stories_by_agent_status.implementing == 0
      assert progress.stories_by_agent_status.reported_done == 0

      # Verified status breakdown
      assert progress.stories_by_verified_status.unverified == 0
      assert progress.stories_by_verified_status.verified == 0
      assert progress.stories_by_verified_status.rejected == 0

      # Epic counts
      assert progress.total_epics == 0
      assert progress.epics_completed == 0

      # Verification percentage
      assert progress.verification_percentage == 0.0

      # Estimated hours
      assert progress.estimated_hours_total == 0
      assert progress.estimated_hours_completed == 0
    end

    test "response shape contains all required keys" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, progress} = Projects.get_project_progress(tenant.id, project.id)

      # Verify all expected keys are present
      assert Map.has_key?(progress, :total_stories)
      assert Map.has_key?(progress, :stories_by_agent_status)
      assert Map.has_key?(progress, :stories_by_verified_status)
      assert Map.has_key?(progress, :total_epics)
      assert Map.has_key?(progress, :epics_completed)
      assert Map.has_key?(progress, :verification_percentage)
      assert Map.has_key?(progress, :estimated_hours_total)
      assert Map.has_key?(progress, :estimated_hours_completed)

      # Verify agent status has all expected sub-keys
      agent_status = progress.stories_by_agent_status
      assert Map.has_key?(agent_status, :pending)
      assert Map.has_key?(agent_status, :contracted)
      assert Map.has_key?(agent_status, :assigned)
      assert Map.has_key?(agent_status, :implementing)
      assert Map.has_key?(agent_status, :reported_done)

      # Verify verified status has all expected sub-keys
      verified_status = progress.stories_by_verified_status
      assert Map.has_key?(verified_status, :unverified)
      assert Map.has_key?(verified_status, :verified)
      assert Map.has_key?(verified_status, :rejected)
    end

    test "verification_percentage is a float" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, progress} = Projects.get_project_progress(tenant.id, project.id)
      assert is_float(progress.verification_percentage)
    end

    test "returns not_found for nonexistent project" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = Projects.get_project_progress(tenant.id, uuid())
    end

    test "returns not_found for project in different tenant (tenant isolation)" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant_b.id})

      assert {:error, :not_found} = Projects.get_project_progress(tenant_a.id, project.id)
    end

    test "returns progress for active project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, _progress} = Projects.get_project_progress(tenant.id, project.id)
    end

    test "returns progress for archived project" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      {:ok, archived} = Projects.archive_project(tenant.id, project)

      assert {:ok, _progress} = Projects.get_project_progress(tenant.id, archived.id)
    end
  end
end
