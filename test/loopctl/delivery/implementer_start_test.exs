defmodule Loopctl.Delivery.ImplementerStartTest do
  @moduledoc """
  US-48.18: a delivery-loop story claimed by `Placement` is STARTED as its assigned agent —
  `Loopctl.Delivery.ImplementerStart` — when its runner moves it `worktree -> implementing`
  (`Loopctl.Delivery.RunnerStages`), with the identity the claim recorded, never the runner's.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ImplementerStart
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    fixture(:verify_ready_story, %{})
  end

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)

  describe "ensure_started/3" do
    test "starts an :assigned story as its assigned agent, once", ctx do
      assert {:ok, :started} = ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)

      story = story(ctx)
      assert story.agent_status == :implementing
      assert story.assigned_agent_id == ctx.implementer_runner.agent_id
      assert story.implementer_dispatch_id == ctx.implementer.id

      assert {:ok, :already_started} =
               ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)
    end

    test "a story nobody claimed has nothing to start", ctx do
      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
          set: [agent_status: :pending, assigned_agent_id: nil]
        )

      assert {:error, :not_claimed} = ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)
    end

    test "a story with no implementer dispatch has no lineage to start under", ctx do
      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
          set: [implementer_dispatch_id: nil]
        )

      assert {:error, :missing_implementer_dispatch} =
               ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)

      assert story(ctx).agent_status == :assigned
    end

    test "tenant isolation: another tenant's id finds no story and starts nothing", ctx do
      other = fixture(:verify_ready_story, %{})

      assert {:error, :not_found} = ImplementerStart.ensure_started(other.tenant.id, ctx.story.id)
      assert story(ctx).agent_status == :assigned
      assert AdminRepo.get!(Story, other.story.id).agent_status == :assigned
    end
  end

  describe "RunnerStages follows the stage" do
    test "a runner's worktree -> implementing starts the story", ctx do
      {1, _} =
        AdminRepo.update_all(from(s in StoryStage, where: s.story_id == ^ctx.story.id),
          set: [stage: :worktree, head_sha: nil, pr_number: nil]
        )

      record =
        fixture(:accepted_dispatch, %{
          tenant_id: ctx.tenant.id,
          runner: ctx.implementer_runner,
          story_id: ctx.story.id,
          claim_epoch: 1
        })

      assert {:ok, %StoryStage{stage: :implementing}} =
               RunnerStages.apply(ctx.tenant.id, ctx.implementer_runner.id, %{
                 dispatch_id: record.dispatch_id,
                 claim_epoch: 1,
                 edge: :forward,
                 from: :worktree,
                 to: :implementing,
                 effects: %{}
               })

      story = story(ctx)
      assert story.agent_status == :implementing
      assert story.assigned_agent_id == ctx.implementer_runner.agent_id
    end
  end
end
