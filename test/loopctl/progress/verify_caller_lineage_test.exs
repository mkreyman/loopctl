defmodule Loopctl.Progress.VerifyCallerLineageTest do
  @moduledoc """
  The L4 caller comparison must bind the principal that actually makes the call — on
  EVERY path that reaches a terminal custody state, not only single-story verify.

  `lineage_status/3` reads an empty caller lineage as "no conflict", so a path that
  simply forgot to resolve the caller's lineage was left with nothing but
  `assigned_agent_id != orchestrator_agent_id` — a condition any orchestrator key
  satisfies trivially. Bulk verify, bulk reject and single-story reject each did.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.BulkOperations
  alias Loopctl.Dispatches
  alias Loopctl.Progress

  setup :verify_on_exit!

  defp dispatched_story do
    tenant = fixture(:tenant)
    impl_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: impl_agent.id})

    {:ok, %{dispatch: sub}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :orchestrator,
        agent_id: fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id,
        parent_dispatch_id: impl.id
      })

    story =
      fixture(:story, %{tenant_id: tenant.id, agent_status: :reported_done})
      |> Ecto.Changeset.change(%{
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> Loopctl.AdminRepo.update!()

    %{tenant: tenant, impl_agent: impl_agent, impl: impl, sub: sub, story: story}
  end

  describe "ensure_verify_allowed/3 (the bulk verify/reject gate)" do
    test "a caller inside the implementer's lineage is blocked even with a different agent_id" do
      ctx = dispatched_story()
      other_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(ctx.story, other_agent.id, ctx.sub.lineage_path)
    end

    test "an unlineaged caller cannot certify dispatch-minted work" do
      # Two legacy env-var keys with distinct agent_ids in one process cleared report,
      # review AND verify: `[]` short-circuits the lineage comparison and the agent-id
      # inequality is trivially true. Where the WORK was dispatch-minted, the certifier
      # must be too — under its OWN code, because `self_verify_blocked` is an L6
      # byzantine signal that escalates to a tenant-wide custody halt and this fires on
      # every call an unmigrated legacy key makes.
      ctx = dispatched_story()
      other_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :caller_lineage_required} =
               Progress.ensure_verify_allowed(ctx.story, other_agent.id, [])
    end

    test "reject is exempt: bad work can always be sent back" do
      # Refusing the unlineaged caller here strands the story at reported_done with no
      # remediation path. Rejecting is not certifying.
      ctx = dispatched_story()
      other_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert :ok = Progress.ensure_verify_allowed(ctx.story, other_agent.id, [], :reject)
    end

    test "a sibling verifier clears the gate in a single-root tenant" do
      # The documented tree is single-rooted (operator root -> orchestrator ->
      # implementer/verifier), so demanding a separate ROOT of the CALLER left no
      # principal able to verify anything. A sibling IS separation.
      tenant = fixture(:tenant)
      agent = fn -> fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator}).id end

      {:ok, %{dispatch: root}} =
        Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.()})

      {:ok, %{dispatch: impl}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :agent,
          agent_id: fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer}).id,
          parent_dispatch_id: root.id
        })

      {:ok, %{dispatch: verifier}} =
        Dispatches.create_dispatch(tenant.id, %{
          role: :orchestrator,
          agent_id: agent.(),
          parent_dispatch_id: root.id
        })

      story =
        fixture(:story, %{tenant_id: tenant.id, agent_status: :reported_done})
        |> Ecto.Changeset.change(%{
          assigned_agent_id: impl.agent_id,
          implementer_dispatch_id: impl.id
        })
        |> Loopctl.AdminRepo.update!()

      assert hd(verifier.lineage_path) == hd(impl.lineage_path)
      assert :ok = Progress.ensure_verify_allowed(story, verifier.agent_id, verifier.lineage_path)

      # The ancestor that dispatched the implementer is still refused.
      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, root.agent_id, root.lineage_path)
    end

    test "a pre-dispatch story still permits an unlineaged independent caller" do
      story = fixture(:story, %{agent_status: :reported_done})
      other = fixture(:agent, %{tenant_id: story.tenant_id, agent_type: :orchestrator})

      assert :ok = Progress.ensure_verify_allowed(story, other.id, [])
    end
  end

  describe "bulk verify resolves the caller lineage server-side" do
    setup do
      ctx = dispatched_story()

      # An independently-rooted orchestrator: the shape that IS allowed to certify.
      {:ok, %{dispatch: independent}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :orchestrator,
          agent_id: fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator}).id
        })

      {:ok, Map.put(ctx, :independent, independent)}
    end

    defp bulk_verify_as(ctx, dispatch) do
      {_raw, api_key} = fixture(:api_key, %{tenant_id: ctx.tenant.id, role: :orchestrator})

      Loopctl.AdminRepo.get!(Loopctl.Dispatches.Dispatch, dispatch.id)
      |> Ecto.Changeset.change(api_key_id: api_key.id)
      |> Loopctl.AdminRepo.update!()

      {:ok, [result]} =
        BulkOperations.bulk_verify(
          ctx.tenant.id,
          [%{"story_id" => ctx.story.id, "result" => "pass", "summary" => "lgtm"}],
          dispatch.agent_id,
          actor_id: api_key.id,
          actor_label: "orchestrator:test"
        )

      result
    end

    test "an orchestrator dispatched under the implementer cannot bulk-verify its work", ctx do
      result = bulk_verify_as(ctx, ctx.sub)

      assert result.status == "error"
      assert result.reason =~ "cannot verify your own implemented work"
    end

    test "an independently-rooted orchestrator clears the custody gate", ctx do
      # The DISCRIMINATING half. Both callers are refused when the lineage is not
      # threaded (an unlineaged caller cannot certify dispatch-minted work), so only
      # this case shows the caller's real lineage reached the gate: it gets past
      # custody and stops at the NEXT gate, the missing review record.
      result = bulk_verify_as(ctx, ctx.independent)

      assert result.status == "error"
      assert result.reason =~ "no independent review record"
    end
  end

  describe "report and review-complete take the same caller-lineage rule" do
    test "an unlineaged reporter cannot report dispatch-minted work" do
      ctx = dispatched_story()

      story =
        ctx.story
        |> Ecto.Changeset.change(%{agent_status: :implementing})
        |> Loopctl.AdminRepo.update!()

      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :implementer})

      assert {:error, :caller_lineage_required} =
               Progress.report_story(ctx.tenant.id, story.id, agent_id: other.id)
    end

    test "a dispatch-minted user-role key may not review its own subtree's work" do
      # A user-role dispatch carries no agent_id, and the nil-reviewer permit used to
      # match on that alone — so an ANCESTOR of the implementer reviewed its own
      # subtree without the lineage it was handed ever being read.
      ctx = dispatched_story()

      assert {:error, :self_review_blocked} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, %{"review_type" => "enhanced"},
                 reviewer_agent_id: nil,
                 reviewer_lineage: ctx.impl.lineage_path
               )
    end

    test "a genuine human operator (no agent, no lineage) still reviews" do
      ctx = dispatched_story()

      assert {:ok, _review} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, %{"review_type" => "enhanced"},
                 reviewer_agent_id: nil,
                 reviewer_lineage: []
               )
    end
  end

  describe "reject_story/4" do
    test "takes the same caller-lineage comparison as verify" do
      ctx = dispatched_story()
      other_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :self_verify_blocked} =
               Progress.reject_story(ctx.tenant.id, ctx.story.id, %{"reason" => "no"},
                 orchestrator_agent_id: other_agent.id,
                 verifier_lineage: ctx.sub.lineage_path
               )
    end
  end
end
