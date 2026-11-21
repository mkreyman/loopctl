defmodule Loopctl.Progress.ClaimHolderTest do
  @moduledoc """
  US-52.14: a claim names its holder (the session, `Loopctl.Holders.Holder`), and every
  claimant verb refuses a different holder, even one with the claimant's own agent.
  The committed two-holder race is in `Loopctl.Progress.ClaimLockTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Holders
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    agent = fixture(:agent, %{agent_type: :implementer})
    tenant_id = agent.tenant_id
    story = fixture(:story, %{tenant_id: tenant_id, agent_status: :contracted})
    h1 = holder(tenant_id, agent.id, "s1")
    h2 = holder(tenant_id, agent.id, "s2")
    %{agent: agent, tenant_id: tenant_id, story: story, h1: h1, h2: h2}
  end

  defp holder(tenant_id, agent_id, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, %{holder: holder}} = Holders.register(tenant_id, agent_id, attrs)
    holder.id
  end

  defp status_changes(story) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^story.tenant_id and a.entity_id == ^story.id and
          a.action == "status_changed"
    )
    |> AdminRepo.aggregate(:count)
  end

  defp as(ctx, holder_id), do: [agent_id: ctx.agent.id, holder_id: holder_id]

  describe "claim" do
    test "writes the holder; the same holder's retry changes nothing; release clears it", ctx do
      {:ok, claimed} = Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      assert claimed.assigned_holder_id == ctx.h1

      assert {:ok, again} = Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      assert again.claim_epoch == claimed.claim_epoch
      assert again.claimed_until == claimed.claimed_until
      assert status_changes(ctx.story) == 1

      {:ok, released} = Progress.unclaim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      assert released.assigned_holder_id == nil
      assert AdminRepo.get!(Story, ctx.story.id).assigned_holder_id == nil
    end

    test "another holder of the same agent, or a key with no holder, is refused", ctx do
      {:ok, _} = Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      held = {:error, {:held_by_other_holder, ctx.h1}}

      assert held == Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h2))
      assert held == Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, nil))
    end
  end

  describe "the claimant verbs" do
    setup ctx do
      {:ok, claimed} = Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      %{claimed: claimed}
    end

    test "refuse a second holder of the same agent, and a key with no holder", ctx do
      held = {:error, {:held_by_other_holder, ctx.h1}}
      epoch = [claim_epoch: ctx.claimed.claim_epoch]

      for holder_id <- [ctx.h2, nil] do
        assert held == Progress.start_story(ctx.tenant_id, ctx.story.id, as(ctx, holder_id))

        assert held ==
                 Progress.renew_claim(ctx.tenant_id, ctx.story.id, as(ctx, holder_id) ++ epoch)

        assert held == Progress.unclaim_story(ctx.tenant_id, ctx.story.id, as(ctx, holder_id))
      end

      assert {:ok, %{agent_status: :implementing}} =
               Progress.start_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))

      for holder_id <- [ctx.h2, nil] do
        assert held == Progress.request_review(ctx.tenant_id, ctx.story.id, as(ctx, holder_id))
      end

      assert {:ok, _} = Progress.request_review(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
    end

    test "the holder renews and releases its own claim", ctx do
      opts = as(ctx, ctx.h1) ++ [claim_epoch: ctx.claimed.claim_epoch]
      assert {:ok, _} = Progress.renew_claim(ctx.tenant_id, ctx.story.id, opts)
      assert {:ok, _} = Progress.unclaim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
    end
  end

  describe "a claim with no holder (made before this release)" do
    test "keeps the agent-id checks", ctx do
      other = fixture(:agent, %{tenant_id: ctx.tenant_id, agent_type: :implementer})
      {:ok, _} = Progress.claim_story(ctx.tenant_id, ctx.story.id, agent_id: ctx.agent.id)

      assert {:error, :not_assigned_agent} =
               Progress.start_story(ctx.tenant_id, ctx.story.id, agent_id: other.id)

      assert {:ok, %{agent_status: :implementing}} =
               Progress.start_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h2))
    end
  end

  describe "bulk claim" do
    test "writes the caller's holder", ctx do
      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_claim(ctx.tenant_id, [ctx.story.id], ctx.agent.id,
          holder_id: ctx.h1
        )

      assert AdminRepo.get!(Story, ctx.story.id).assigned_holder_id == ctx.h1
    end
  end

  describe "tenant isolation" do
    test "another tenant's caller cannot reach a held story", ctx do
      {:ok, _} = Progress.claim_story(ctx.tenant_id, ctx.story.id, as(ctx, ctx.h1))
      stranger = fixture(:agent, %{agent_type: :implementer})

      assert {:error, :not_found} =
               Progress.claim_story(stranger.tenant_id, ctx.story.id, agent_id: stranger.id)
    end
  end
end
