defmodule Loopctl.Delivery.StagesIssueClosureTest do
  @moduledoc """
  THE WIRING (#805): a terminal verdict on a story that came from a reported issue records
  the closure intent in the SAME transaction, and every other transition records nothing.

  This module is about the CALL SITE. `Loopctl.Delivery.IssueCloserTest` covers what the
  closer then does with the row, and `Loopctl.Intake.IssueClosuresTest` covers the row's own
  state machine. A change that leaves both of those green while removing the hook here would
  ship a feature nothing ever triggers, which is why this file exists separately.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Repo

  setup :verify_on_exit!

  setup do
    story = fixture(:stage_story, %{})
    tenant_id = story.tenant_id
    record = fixture(:intake_record, %{tenant_id: tenant_id, issue_number: 512})

    %{story: story, tenant_id: tenant_id, record: record}
  end

  describe "the shipped verdict" do
    test "deployed -> verified on a linked story records a shipped closure", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      assert {:ok, _row} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified},
                 claim_epoch: 0,
                 actor_label: "worker:post_deploy_verification",
                 actor_lineage: []
               )

      assert %IssueClosure{} = closure = closure(ctx)
      assert closure.verdict == :shipped
      assert closure.status == :pending
      assert closure.issue_number == 512
      assert closure.repo_full_name == "mkreyman/home_care_billing"
      assert closure.intake_record_id == ctx.record.id
    end

    test "the SAME transition on an UNLINKED story records nothing and is not an error", ctx do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      assert {:ok, _row} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified},
                 claim_epoch: 0,
                 actor_label: "worker:post_deploy_verification",
                 actor_lineage: []
               )

      assert closure(ctx) == nil
    end
  end

  describe "the not-actionable verdict" do
    test "triaged -> failed on :triage_reject records a not_actionable closure", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :triaged})

      assert {:ok, _row} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:triaged, :failed, :triage_reject},
                 claim_epoch: 0,
                 actor_label: "triage",
                 actor_lineage: []
               )

      assert %IssueClosure{verdict: :not_actionable, status: :pending} = closure(ctx)
    end

    test "the same {triaged, failed} pair over :budget_exceeded records NOTHING", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :triaged})

      # Same source and destination stage, opposite meaning to the reporter. This is the case
      # that makes `resolution_verdict/1` read the EDGE rather than the destination.
      assert {:ok, _row} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:triaged, :failed, :budget_exceeded},
                 claim_epoch: 0,
                 actor_label: "control",
                 actor_lineage: []
               )

      assert closure(ctx) == nil
    end
  end

  describe "an escalation" do
    test "records nothing, even on a linked story", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      assert {:ok, _row} =
               Stages.advance(
                 ctx.tenant_id,
                 ctx.story.id,
                 {:deployed, :escalated, :verification_failed},
                 claim_epoch: 0,
                 reason: "the deploy did not carry the merge",
                 actor_label: "worker:post_deploy_verification",
                 actor_lineage: []
               )

      assert closure(ctx) == nil
    end
  end

  describe "atomicity and replay" do
    test "a rolled-back transition records no intent", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      # A stale epoch rolls the whole transaction back. The stage does not move, and the
      # closure row must not exist either — an outbox that could commit without its verdict
      # would close a reporter's issue for work that was never marked shipped.
      assert {:error, :stale_claim_epoch} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified},
                 claim_epoch: 99,
                 actor_label: "worker:post_deploy_verification",
                 actor_lineage: []
               )

      assert closure(ctx) == nil
      assert %{stage: :deployed} = Stages.get(ctx.tenant_id, ctx.story.id)
    end

    test "a second attempt at the same verdict is refused and leaves one row", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      opts = [
        claim_epoch: 0,
        actor_label: "worker:post_deploy_verification",
        actor_lineage: []
      ]

      assert {:ok, _row} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified}, opts)

      assert {:error, :stale_stage} =
               Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified}, opts)

      assert [%IssueClosure{}] = all_closures(ctx)
    end

    test "verified -> done records nothing further", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      opts = [claim_epoch: 0, actor_label: "control", actor_lineage: []]

      {:ok, _} = Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified}, opts)
      {:ok, _} = Stages.advance(ctx.tenant_id, ctx.story.id, {:verified, :done}, opts)

      assert [%IssueClosure{verdict: :shipped}] = all_closures(ctx)
    end
  end

  describe "the resolution table" do
    test "names exactly the two transitions that close, and no others", _ctx do
      table = StageMachine.resolution_transitions()

      assert table == %{
               {:deployed, :verified, :forward} => :shipped,
               {:triaged, :failed, :triage_reject} => :not_actionable
             }

      # Every entry is a real transition, so neither can be a mapping nothing can reach.
      for transition <- Map.keys(table) do
        assert transition in StageMachine.transitions()
      end
    end

    test ":triage_reject is not something a runner may report", _ctx do
      refute {:triaged, :failed, :triage_reject} in StageMachine.runner_transitions()

      # And neither is the shipped verdict, for the same reason: both are verdicts control
      # reaches about a session, not things the session observed about its own work.
      refute {:deployed, :verified, :forward} in StageMachine.runner_transitions()
    end
  end

  describe "tenant isolation" do
    test "another tenant sees no closure for this story", ctx do
      link(ctx)
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :deployed})

      {:ok, _} =
        Stages.advance(ctx.tenant_id, ctx.story.id, {:deployed, :verified},
          claim_epoch: 0,
          actor_label: "control",
          actor_lineage: []
        )

      other = fixture(:tenant)

      assert read(other.id, fn -> Repo.all(from(c in IssueClosure)) end) == []
      assert [%IssueClosure{}] = all_closures(ctx)
    end
  end

  # Sets the link the way `Stages` will read it. `Stories.create_story/3` is the production
  # writer and has its own test; here the point is what the transition does with the field.
  defp link(ctx) do
    read(ctx.tenant_id, fn ->
      from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^ctx.story.id)
      |> Repo.update_all(set: [intake_record_id: ctx.record.id])
    end)
  end

  # The closure row is written by `Stages` on `Loopctl.Repo` inside `with_tenant/2`, which in
  # the sandbox is a different connection from `AdminRepo` — so it is read back on the same
  # one rather than through `IssueClosures.get/2`.
  defp closure(ctx), do: ctx |> all_closures() |> List.first()

  defp all_closures(ctx) do
    read(ctx.tenant_id, fn ->
      Repo.all(from c in IssueClosure, where: c.story_id == ^ctx.story.id)
    end)
  end

  defp read(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end
end
