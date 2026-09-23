defmodule Loopctl.Progress.ReleaseEndedSessionTest do
  @moduledoc """
  US-44.3: `Progress.release_ended_session/4` — the release a runner's `crashed` or
  `usage_exhausted` report causes. It is the lease reclaim with the lease taken out of the
  question: the same release, the same `:runner_lost` stage edge, and the same audit entry,
  written by the one private builder both call.

  On `AdminRepo`, the connection every release path takes, so async: the story, its claim and
  its stage row are all made there. The whole path from a runner's message — ledger on `Repo`,
  release on `AdminRepo` — is in `Loopctl.Delivery.SessionEndReleaseTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  # A claim with most of its 24h lease left and its stage row in flight — the state a crash
  # report arrives in, and the one a lease reclaim could not touch for another day.
  defp claimed_at(stage) do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})
    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

    row =
      fixture(:story_stage, %{
        repo: AdminRepo,
        tenant_id: tenant.id,
        story_id: story.id,
        stage: stage,
        claim_epoch: claimed.claim_epoch
      })

    %{tenant_id: tenant.id, story: claimed, row: row}
  end

  defp release(ctx, reason \\ "crashed", epoch \\ nil) do
    Progress.release_ended_session(
      ctx.tenant_id,
      ctx.story.id,
      epoch || ctx.story.claim_epoch,
      session_reason: reason,
      actor_label: "runner:test"
    )
  end

  defp audit_entries(story) do
    from(a in AuditLog,
      where: a.tenant_id == ^story.tenant_id and a.entity_id == ^story.id,
      where: a.action in ["claim_lease_expired", "claim_session_ended"]
    )
    |> AdminRepo.all()
  end

  test "releases the claim with most of its lease left, over runner_lost (AC-44.3.4)" do
    ctx = claimed_at(:implementing)
    assert DateTime.diff(ctx.story.claimed_until, DateTime.utc_now(), :hour) >= 23

    assert {:ok, released} = release(ctx)

    assert released.agent_status == :pending
    assert released.assigned_agent_id == nil
    assert released.claimed_until == nil
    assert released.claim_epoch == ctx.story.claim_epoch + 1
    # The backfill launder guard's column, stamped exactly as every other release stamps it.
    assert released.lifecycle_entered_at != nil

    row = AdminRepo.get!(StoryStage, ctx.row.id)
    assert row.stage == :queued
    assert row.claim_epoch == released.claim_epoch
    assert row.attempts == %{"runner_lost" => 1}
  end

  test "writes the SAME audit entry a lease reclaim writes, naming what actually happened" do
    crashed = claimed_at(:implementing)
    {:ok, _} = release(crashed, "usage_exhausted")

    # A real reclaim, for the entry to compare against rather than a copy of its keys.
    expired = claimed_at(:implementing)

    {1, _} =
      from(s in Story, where: s.id == ^expired.story.id)
      |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])

    {:ok, _} =
      Progress.reclaim_expired_claim(
        expired.tenant_id,
        expired.story.id,
        expired.story.claim_epoch
      )

    [ours] = audit_entries(crashed.story)
    [reclaim] = audit_entries(expired.story)

    for field <- [:entity_type, :actor_type, :actor_id] do
      assert Map.fetch!(ours, field) == Map.fetch!(reclaim, field), inspect(field)
    end

    assert Map.keys(ours.old_state) == Map.keys(reclaim.old_state)
    assert ours.old_state["agent_status"] == "assigned"
    assert ours.old_state["claim_epoch"] == crashed.story.claim_epoch

    # The reclaim's `new_state`, plus the one key that says which report released it.
    assert Map.drop(ours.new_state, ["session_ended_reason"]) |> Map.keys() |> Enum.sort() ==
             reclaim.new_state |> Map.keys() |> Enum.sort()

    assert ours.new_state["agent_status"] == "pending"
    assert ours.new_state["session_ended_reason"] == "usage_exhausted"

    # NOT `claim_lease_expired`: no lease expired, and the log must not say one did.
    assert reclaim.action == "claim_lease_expired"
    assert ours.action == "claim_session_ended"
    assert ours.actor_label == "runner:test"
  end

  test "a claim at another epoch is not this session's, and nothing is written (AC-44.3.6)" do
    ctx = claimed_at(:implementing)

    assert {:error, :claim_not_held} = release(ctx, "crashed", ctx.story.claim_epoch - 1)

    assert AdminRepo.get!(Story, ctx.story.id).claim_epoch == ctx.story.claim_epoch
    assert AdminRepo.get!(StoryStage, ctx.row.id).stage == :implementing
    assert audit_entries(ctx.story) == []
  end

  test "a claim already released, or handed to review, is not released again" do
    released = claimed_at(:implementing)
    {:ok, _} = release(released)
    assert {:error, :claim_not_held} = release(released)
    assert length(audit_entries(released.story)) == 1

    in_review = claimed_at(:implementing)

    {1, _} =
      from(s in Story, where: s.id == ^in_review.story.id)
      |> AdminRepo.update_all(set: [review_requested_at: DateTime.utc_now()])

    assert {:error, :claim_not_held} = release(in_review)
    assert AdminRepo.get!(Story, in_review.story.id).agent_status in [:assigned, :implementing]
  end

  test "only the two reasons that release a claim are accepted" do
    ctx = claimed_at(:implementing)

    assert_raise ArgumentError, fn -> release(ctx, "completed") end
    assert AdminRepo.get!(Story, ctx.story.id).claim_epoch == ctx.story.claim_epoch
  end

  test "tenant isolation: another tenant's id cannot release the story" do
    ctx = claimed_at(:implementing)
    other = fixture(:tenant)

    assert {:error, :not_found} =
             Progress.release_ended_session(other.id, ctx.story.id, ctx.story.claim_epoch,
               session_reason: "crashed",
               actor_label: "runner:test"
             )

    assert AdminRepo.get!(Story, ctx.story.id).claim_epoch == ctx.story.claim_epoch
  end
end
