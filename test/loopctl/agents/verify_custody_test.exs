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
  alias Loopctl.Delivery.ImplementerStart
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

  describe "AC-48.18.3: on the pr route only the bound verifier reports, reviews and verifies" do
    setup ctx do
      b = mint(ctx, %{})
      {:ok, _} = bind(ctx, b.id)
      {:ok, _} = ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)
      c = mint(ctx, %{agent_id: fixture(:agent, %{tenant_id: ctx.tenant.id}).id})
      %{b: b, c: c}
    end

    test "a separately rooted dispatch control did not bind cannot report", ctx do
      assert {:error, :pr_route_verifier_only} = report(ctx, ctx.c)
      assert story(ctx).agent_status == :implementing
    end

    test "after B's report neither a human-operator key nor another dispatch may review, " <>
           "and no other dispatch may verify, on any verify path",
         ctx do
      assert {:ok, _} = report(ctx, ctx.b)

      assert {:error, :pr_route_verifier_only} = review(ctx, nil, [])
      assert {:error, :pr_route_verifier_only} = review(ctx, ctx.c.agent_id, ctx.c.lineage_path)
      assert {:ok, _} = review(ctx, ctx.b.agent_id, ctx.b.lineage_path)

      assert {:error, :pr_route_verifier_only} =
               Progress.verify_story(ctx.tenant.id, ctx.story.id, %{"summary" => "x"},
                 orchestrator_agent_id: ctx.c.agent_id,
                 verifier_lineage: ctx.c.lineage_path
               )

      assert {:error, :pr_route_verifier_only} =
               Progress.ensure_verify_allowed(story(ctx), ctx.c.agent_id, ctx.c.lineage_path)

      # Reject is remediation and is not gated here.
      refute Progress.ensure_verify_allowed(
               story(ctx),
               ctx.c.agent_id,
               ctx.c.lineage_path,
               :reject
             ) == {:error, :pr_route_verifier_only}

      assert story(ctx).verified_status == :unverified
    end

    test "a story on no live pr-mode source is not gated", ctx do
      {1, _} =
        from(s in Source, where: s.id == ^ctx.source.id)
        |> AdminRepo.update_all(set: [revoked_at: DateTime.utc_now()])

      assert {:ok, _} = report(ctx, ctx.c)
    end
  end

  describe "a verdict never skips an act it did not do" do
    test "a report found under another agent cancels the verdict instead of skipping", ctx do
      args = answered!(ctx)
      {:ok, _} = ImplementerStart.ensure_started(ctx.tenant.id, ctx.story.id)
      other = fixture(:agent, %{tenant_id: ctx.tenant.id})

      ctx.story
      |> Ecto.Changeset.change(
        agent_status: :reported_done,
        reported_done_at: DateTime.utc_now(),
        reported_by_agent_id: other.id
      )
      |> AdminRepo.update!()

      assert {:cancel, :custody_act_by_other} = VerifyVerdict.apply(args)
      assert story(ctx).verified_status == :unverified
    end
  end

  describe "a rebind takes the recorded head with the verification" do
    test "binding a new verifier clears verified_head_sha", ctx do
      verified!(ctx)
      assert {:ok, _} = bind(ctx, mint(ctx, %{}).id)

      assert Stages.get(ctx.tenant.id, ctx.story.id).verified_head_sha == nil
      assert story(ctx).verified_status == :unverified
    end

    test "a superseded verdict's late head write is refused and retires nothing", ctx do
      verified!(ctx)
      superseded = story(ctx).verifier_dispatch_id
      read = Stages.get(ctx.tenant.id, ctx.story.id)
      b2 = mint(ctx, %{})
      assert {:ok, _} = bind(ctx, b2.id)

      assert {:error, {:verified_head_not_recorded, :verifier_rebound}} =
               VerifyVerdict.record_verified_head(ctx.tenant.id, ctx.story.id, read, superseded)

      assert Stages.get(ctx.tenant.id, ctx.story.id).verified_head_sha == nil
      assert story(ctx).verifier_dispatch_id == b2.id
    end
  end

  defp report(ctx, d) do
    Progress.report_story(ctx.tenant.id, ctx.story.id,
      agent_id: d.agent_id,
      reporter_lineage: d.lineage_path
    )
  end

  defp review(ctx, agent_id, lineage) do
    Progress.record_review(ctx.tenant.id, ctx.story.id, %{"review_type" => "test"},
      reviewer_agent_id: agent_id,
      reviewer_lineage: lineage
    )
  end

  # A pass applied for real: placement binds B, the verdict is recorded and applied.
  defp verified!(ctx) do
    assert {:ok, :verified} = VerifyVerdict.apply(answered!(ctx))

    assert AdminRepo.one(
             from s in StoryStage, where: s.story_id == ^ctx.story.id, select: s.verified_head_sha
           ) == ctx.head
  end

  # Placement binds B and the pass verdict is recorded on B's ledger row; returns the job args.
  defp answered!(ctx) do
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

    %{
      "tenant_id" => ctx.tenant.id,
      "story_id" => ctx.story.id,
      "dispatch_id" => payload["dispatch_id"]
    }
  end
end
