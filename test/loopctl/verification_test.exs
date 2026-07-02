defmodule Loopctl.VerificationTest do
  @moduledoc """
  Tests for US-26.4.2 — verification runs.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Verification
  alias Loopctl.Verification.VerificationRun

  setup :verify_on_exit!

  defp setup_ctx do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    %{tenant: tenant, story: story}
  end

  describe "create_run/3" do
    test "creates a pending verification run" do
      %{tenant: tenant, story: story} = setup_ctx()

      sha = String.duplicate("a", 40)

      assert {:ok, run} =
               Verification.create_run(tenant.id, story.id, %{commit_sha: sha})

      assert run.status == "pending"
      assert run.story_id == story.id
      assert run.commit_sha == sha
    end
  end

  describe "create_run_and_enqueue/3 (atomic run row + Oban job)" do
    test "creates the run and returns {:ok, run}" do
      %{tenant: tenant, story: story} = setup_ctx()
      sha = String.duplicate("a", 40)

      assert {:ok, run} =
               Verification.create_run_and_enqueue(tenant.id, story.id, %{commit_sha: sha})

      assert run.commit_sha == sha
      # The run row is persisted (committed with its enqueued job).
      assert AdminRepo.get(VerificationRun, run.id)
    end

    test "rolls back atomically on failure — no orphaned 'pending' run row" do
      %{tenant: tenant, story: story} = setup_ctx()

      # An invalid commit_sha makes the :run insert step fail. Because the run
      # insert and the Oban job insert share ONE transaction, a failure in
      # either step rolls back the whole thing — so there is never an orphaned
      # "pending" run left behind with no job to execute it (nor a job with no
      # run). This is the atomicity guarantee that replaces the old
      # create_run + discarded Oban.insert two-step.
      assert {:error, %Ecto.Changeset{}} =
               Verification.create_run_and_enqueue(tenant.id, story.id, %{
                 commit_sha: "../../etc"
               })

      assert AdminRepo.all(from(r in VerificationRun, where: r.story_id == ^story.id)) == []
    end
  end

  describe "start_run/1 and complete_run/3" do
    test "transitions through running → pass" do
      %{tenant: tenant, story: story} = setup_ctx()
      {:ok, run} = Verification.create_run(tenant.id, story.id)

      {:ok, running} = Verification.start_run(run)
      assert running.status == "running"
      assert running.started_at != nil

      {:ok, passed} = Verification.complete_run(running, "pass", %{"AC-1" => "pass"})
      assert passed.status == "pass"
      assert passed.completed_at != nil
      assert passed.ac_results["AC-1"] == "pass"
    end
  end

  describe "list_runs/3" do
    test "returns runs for a story" do
      %{tenant: tenant, story: story} = setup_ctx()
      Verification.create_run(tenant.id, story.id)
      Verification.create_run(tenant.id, story.id)

      result = Verification.list_runs(tenant.id, story.id)
      assert result.meta.total_count == 2
    end
  end
end
