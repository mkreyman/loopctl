defmodule Loopctl.Agents.VerifyCustodyTest do
  @moduledoc """
  US-48.18's custody seams, one at a time: `Progress.bind_verifier_dispatch/4` refuses every
  verifier dispatch it cannot prove independent of the implementer, a head that leaves the
  story takes its verification with it (`Progress.invalidate_verification/3` from
  `Loopctl.Delivery.Stages`), and `Stages.advance/4`'s `:row_guard` rolls the move back.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.VerifierPlacement
  alias Loopctl.Agents.VerifyVerdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    fixture(:verify_ready_story, %{})
  end

  defp mint(ctx, attrs) do
    {:ok, %{dispatch: d}} =
      Dispatches.create_dispatch(
        ctx.tenant.id,
        Map.merge(
          %{role: :orchestrator, agent_id: ctx.verifier_runner.agent_id, story_id: ctx.story.id},
          attrs
        )
      )

    d
  end

  defp bind(ctx, dispatch_id),
    do: Progress.bind_verifier_dispatch(ctx.tenant.id, ctx.story.id, dispatch_id)

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)

  describe "bind_verifier_dispatch/4 refuses a verifier it cannot show independent" do
    test "an independently rooted dispatch of another agent, minted for this story, binds", ctx do
      b = mint(ctx, %{})
      assert {:ok, %Story{verifier_dispatch_id: id}} = bind(ctx, b.id)
      assert id == b.id
    end

    test "a dispatch inside the implementer's chain shares its root", ctx do
      b = mint(ctx, %{parent_dispatch_id: ctx.implementer.id})
      assert {:error, :verifier_shares_root} = bind(ctx, b.id)
      assert story(ctx).verifier_dispatch_id == nil
    end

    test "a dispatch of the implementer's own agent is the same agent", ctx do
      b = mint(ctx, %{agent_id: ctx.implementer_runner.agent_id})
      assert {:error, :verifier_same_agent} = bind(ctx, b.id)
    end

    test "a dispatch naming no agent is refused as the same agent", ctx do
      {:ok, %{dispatch: b}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{role: :user, story_id: ctx.story.id})

      assert {:error, :verifier_same_agent} = bind(ctx, b.id)
    end

    test "a dispatch minted for another story", ctx do
      other = fixture(:story, %{tenant_id: ctx.tenant.id})
      b = mint(ctx, %{story_id: other.id})
      assert {:error, :verifier_not_for_story} = bind(ctx, b.id)
    end

    test "a revoked dispatch", ctx do
      b = mint(ctx, %{})
      {:ok, _} = Dispatches.revoke(ctx.tenant.id, b.id, actor_lineage: [])
      assert {:error, :dispatch_revoked} = bind(ctx, b.id)
    end

    test "a story with no implementer dispatch has nothing to be separate from", ctx do
      ctx.story
      |> Ecto.Changeset.change(implementer_dispatch_id: nil)
      |> AdminRepo.update!()

      assert {:error, :missing_implementer_dispatch} = bind(ctx, mint(ctx, %{}).id)
    end

    test "an implementer dispatch that does not load in the tenant fails closed", ctx do
      # The foreign key holds a real row, so the one way the tenant-scoped read misses is a
      # row of another tenant.
      foreign = fixture(:verify_ready_story, %{}).implementer

      ctx.story
      |> Ecto.Changeset.change(implementer_dispatch_id: foreign.id)
      |> AdminRepo.update!()

      assert {:error, :unresolvable_dispatch_lineage} = bind(ctx, mint(ctx, %{}).id)
    end

    test "a dispatch id that is not a dispatch", ctx do
      assert {:error, :unresolvable_dispatch_lineage} = bind(ctx, Ecto.UUID.generate())
    end

    test "tenant isolation: another tenant's dispatch is not resolvable here", ctx do
      other = fixture(:verify_ready_story, %{})
      b = mint(other, %{})
      assert {:error, :unresolvable_dispatch_lineage} = bind(ctx, b.id)
      assert story(ctx).verifier_dispatch_id == nil
    end

    test "binding a NEW verifier retires an earlier cycle's report and verification", ctx do
      ctx.story
      |> Ecto.Changeset.change(
        agent_status: :reported_done,
        verified_status: :verified,
        verified_at: DateTime.utc_now()
      )
      |> AdminRepo.update!()

      assert {:ok, bound} = bind(ctx, mint(ctx, %{}).id)
      assert bound.verified_status == :unverified
      assert bound.agent_status == :implementing
    end
  end

  describe "TC-48.18.2: a verified story that returns to work is no longer verified" do
    test "ci -> implementing over :base_moved retires the verification and its head", ctx do
      verified!(ctx)

      assert {:ok, row} =
               Stages.advance(ctx.tenant.id, ctx.story.id, {:ci, :implementing, :base_moved},
                 claim_epoch: 1,
                 reason: "base moved",
                 actor_label: "test",
                 actor_role: :agent,
                 actor_lineage: []
               )

      assert row.head_sha == nil
      assert row.verified_head_sha == nil

      story = story(ctx)
      assert story.verified_status == :unverified
      assert story.agent_status == :implementing
      refute Progress.merge_custody_status(story) == :ok
    end

    test "a story on no live pr-mode source is left alone by the same edge", ctx do
      verified!(ctx)

      {1, _} =
        from(s in Source, where: s.id == ^ctx.source.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      assert {:ok, _row} =
               Stages.advance(ctx.tenant.id, ctx.story.id, {:ci, :implementing, :base_moved},
                 claim_epoch: 1,
                 reason: "base moved",
                 actor_label: "test",
                 actor_role: :agent,
                 actor_lineage: []
               )

      assert story(ctx).verified_status == :verified
    end
  end

  describe "invalidate_verification/3" do
    test "refuses to run outside the caller's transaction", ctx do
      assert_raise ArgumentError, fn ->
        Progress.invalidate_verification(ctx.tenant.id, ctx.story.id, repo: AdminRepo)
      end
    end

    test "leaves a story with nothing to retire unchanged", ctx do
      assert {:ok, {:ok, :unchanged, nil}} =
               AdminRepo.transaction(fn ->
                 Progress.invalidate_verification(ctx.tenant.id, ctx.story.id, repo: AdminRepo)
               end)
    end

    test "tenant isolation: another tenant's id resolves no story", ctx do
      other = fixture(:verify_ready_story, %{})

      assert {:ok, {:error, :not_found}} =
               AdminRepo.transaction(fn ->
                 Progress.invalidate_verification(other.tenant.id, ctx.story.id, repo: AdminRepo)
               end)
    end
  end

  describe "Stages.advance/4's :row_guard" do
    test "an error from the guard rolls the move back and is the answer", ctx do
      assert {:error, :verdict_stale} =
               Stages.advance(ctx.tenant.id, ctx.story.id, {:ci, :implementing, :verify_rejected},
                 claim_epoch: 1,
                 reason: "x",
                 actor_label: "test",
                 actor_role: :agent,
                 actor_lineage: [],
                 row_guard: fn %StoryStage{} -> {:error, :verdict_stale} end
               )

      assert %StoryStage{stage: :ci, head_sha: head} = Stages.get(ctx.tenant.id, ctx.story.id)
      assert head == ctx.head
    end

    test "the guard is handed the locked pre-image", ctx do
      test_pid = self()

      assert {:ok, %StoryStage{stage: :implementing}} =
               Stages.advance(ctx.tenant.id, ctx.story.id, {:ci, :implementing, :verify_rejected},
                 claim_epoch: 1,
                 reason: "x",
                 actor_label: "test",
                 actor_role: :agent,
                 actor_lineage: [],
                 row_guard: fn row ->
                   send(test_pid, {:pre_image, row.stage, row.head_sha})
                   :ok
                 end
               )

      assert_received {:pre_image, :ci, head}
      assert head == ctx.head
    end
  end

  # A pass applied for real: placement binds B, the verdict is recorded and applied.
  defp verified!(ctx) do
    test_pid = self()

    assert {:ok, :dispatched} =
             VerifierPlacement.place(
               ctx.tenant.id,
               ctx.story.id,
               %{wall_clock_seconds: 1_200, max_turns: 40},
               api_key: ctx.operator_key,
               runners: fn _repo -> [ctx.verifier_runner] end,
               dispatch: fn _t, _r, payload ->
                 send(test_pid, {:payload, payload})
                 :ok
               end,
               actor_label: "test"
             )

    assert_received {:payload, payload}

    fixture(:accepted_dispatch, %{
      tenant_id: ctx.tenant.id,
      runner: ctx.verifier_runner,
      dispatch_id: payload["dispatch_id"],
      story_id: ctx.story.id,
      claim_epoch: 1,
      kind: "verify"
    })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _} =
               AgentResult.apply(ctx.tenant.id, ctx.verifier_runner.id, %{
                 dispatch_id: payload["dispatch_id"],
                 claim_epoch: 1,
                 spec: %{id: "verify", version: 1},
                 result: %{"verdict" => "pass", "head_sha" => ctx.head, "findings" => []}
               })
    end)

    assert {:ok, :verified} =
             VerifyVerdict.apply(%{
               "tenant_id" => ctx.tenant.id,
               "story_id" => ctx.story.id,
               "dispatch_id" => payload["dispatch_id"]
             })

    assert AdminRepo.one(
             from s in StoryStage, where: s.story_id == ^ctx.story.id, select: s.verified_head_sha
           ) == ctx.head
  end
end
