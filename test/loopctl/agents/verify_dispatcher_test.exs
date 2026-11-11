defmodule Loopctl.Agents.VerifyDispatcherTest do
  @moduledoc """
  US-48.18: which stories `verify@1` selects (`Dispatcher.candidates/2` over its predicates),
  and the verifier pass of `Dispatcher.run/2` — its operator key above all (AC-48.18.5): a
  `:user` key a dispatch minted is never the tenant's operator, so it never becomes the root a
  verifier dispatch hangs from.

  No runner socket joins here, so `Selection` admits none and a pass that reaches placement
  answers `:no_runner`; placement with runners is `Loopctl.Agents.VerifyFlowTest`'s.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Dispatcher
  alias Loopctl.Agents.Specs.VerifyV1
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @budgets %{wall_clock_seconds: 1_200, max_turns: 40}

  setup do
    fixture(:verify_ready_story, %{})
  end

  defp selected?(ctx) do
    VerifyV1.spec()
    |> Dispatcher.candidates(500)
    |> Enum.any?(&(&1 == %{tenant_id: ctx.tenant.id, story_id: ctx.story.id}))
  end

  defp set_stage(ctx, set) do
    {1, _} =
      AdminRepo.update_all(from(s in StoryStage, where: s.story_id == ^ctx.story.id), set: set)
  end

  defp set_story(ctx, set) do
    {1, _} = AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id), set: set)
  end

  defp run do
    Dispatcher.run(VerifyV1.spec(),
      limit: 500,
      enabled?: true,
      budgets: @budgets,
      dispatch: fn _t, _r, _p -> flunk("nothing may be pushed without a runner") end
    )
  end

  describe "candidates" do
    test "a pr-route story at ci with an unverified head, claimed and dispatched, is one", ctx do
      assert selected?(ctx)
    end

    test "a head already verified is not", ctx do
      set_stage(ctx, verified_head_sha: ctx.head)
      refute selected?(ctx)
    end

    test "a verification at ANOTHER head does not count for this one", ctx do
      set_stage(ctx, verified_head_sha: String.duplicate("c", 40))
      assert selected?(ctx)
    end

    test "a row with no head is not", ctx do
      set_stage(ctx, head_sha: nil)
      refute selected?(ctx)
    end

    test "a story not at ci is not", ctx do
      set_stage(ctx, stage: :pr_open)
      refute selected?(ctx)
    end

    test "a story on a chg source is not", ctx do
      {1, _} =
        AdminRepo.update_all(from(s in Loopctl.Intake.Source, where: s.id == ^ctx.source.id),
          set: [
            mode: :chg,
            change_events_secret: "chg-secret",
            chg_root_dispatch_id: ctx.implementer.id
          ]
        )

      refute selected?(ctx)
    end

    test "a story with no implementer dispatch is not", ctx do
      set_story(ctx, implementer_dispatch_id: nil)
      refute selected?(ctx)
    end

    test "a story no longer claimed is not", ctx do
      set_story(ctx, agent_status: :pending, assigned_agent_id: nil)
      refute selected?(ctx)
    end

    test "a story whose verifier dispatch is live is not, and is again once it is revoked",
         ctx do
      {:ok, %{dispatch: b}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :orchestrator,
          agent_id: ctx.verifier_runner.agent_id,
          story_id: ctx.story.id
        })

      set_story(ctx, verifier_dispatch_id: b.id)
      refute selected?(ctx)

      {:ok, _} = Dispatches.revoke(ctx.tenant.id, b.id, actor_lineage: [])
      assert selected?(ctx)
    end

    test "tenant isolation: each tenant's story is selected under its own tenant only", ctx do
      other = fixture(:verify_ready_story, %{})

      candidates = Dispatcher.candidates(VerifyV1.spec(), 500)

      assert %{tenant_id: ctx.tenant.id, story_id: ctx.story.id} in candidates
      assert %{tenant_id: other.tenant.id, story_id: other.story.id} in candidates
      refute %{tenant_id: other.tenant.id, story_id: ctx.story.id} in candidates
    end
  end

  describe "the verifier pass" do
    test "with the tenant's operator key and no runner connected, the story has no runner",
         ctx do
      assert {:ok, outcomes} = run()
      assert :no_runner in outcomes
      assert AdminRepo.get!(Story, ctx.story.id).verifier_dispatch_id == nil
    end

    test "AC-48.18.5: a :user key a dispatch minted is not an operator key", ctx do
      {1, _} =
        AdminRepo.update_all(from(k in ApiKey, where: k.id == ^ctx.operator_key.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      {:ok, %{dispatch: minted}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :user,
          agent_id: fixture(:agent, %{tenant_id: ctx.tenant.id}).id
        })

      assert is_nil(AdminRepo.get!(ApiKey, minted.api_key_id).revoked_at)

      {result, log} = with_log(fn -> run() end)

      assert {:ok, [:blocked]} = result
      assert log =~ "no_operator_key"
      assert AdminRepo.get!(Story, ctx.story.id).verifier_dispatch_id == nil
    end

    test "AC-48.18.5: an OLDER dispatch-minted :user key never displaces the operator's", ctx do
      {:ok, %{dispatch: minted}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :user,
          agent_id: fixture(:agent, %{tenant_id: ctx.tenant.id}).id
        })

      # Oldest first is the operator rule, so the minted key would be picked without the
      # exclusion — and placement would refuse it, blocking a tenant that HAS an operator.
      {1, _} =
        AdminRepo.update_all(from(k in ApiKey, where: k.id == ^minted.api_key_id),
          set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
        )

      assert {:ok, outcomes} = run()
      assert :no_runner in outcomes
      refute :blocked in outcomes
    end

    test "off, the pass reads nothing", _ctx do
      assert {:ok, []} =
               Dispatcher.run(VerifyV1.spec(), limit: 5, enabled?: false, budgets: @budgets)
    end
  end
end
