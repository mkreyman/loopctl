defmodule Loopctl.Workers.ReclaimExpiredClaimsWorkerTest do
  @moduledoc """
  #803 — the sweep that releases story claims whose lease ran out.

  Claims are made through the real `Progress.claim_story/3`, then their `claimed_until`
  is forced into the past with AdminRepo, the same approach
  `RevokeExpiredDispatchesWorkerTest` takes for dispatch expiry.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Progress
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReclaimExpiredClaimsWorker

  setup :verify_on_exit!

  defp claimed_story(tenant) do
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})
    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)
    %{story: claimed, agent: agent}
  end

  defp force(story, fields) do
    {1, _} = from(s in Story, where: s.id == ^story.id) |> AdminRepo.update_all(set: fields)
    AdminRepo.get!(Story, story.id)
  end

  defp expire(story),
    do: force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))

  defp sweep, do: ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})

  defp reload(story), do: AdminRepo.get!(Story, story.id)

  defp lease_expired_audit(story) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^story.tenant_id and a.entity_id == ^story.id and
          a.action == "claim_lease_expired"
    )
    |> AdminRepo.all()
  end

  describe "perform/1" do
    test "releases an expired claim: pending, epoch bumped, lifecycle stamped, audited" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      story = expire(story)

      assert :ok = sweep()

      released = reload(story)
      assert released.agent_status == :pending
      assert released.assigned_agent_id == nil
      assert released.claimed_until == nil
      assert released.claim_epoch == story.claim_epoch + 1
      assert %DateTime{} = released.lifecycle_entered_at

      assert [entry] = lease_expired_audit(story)
      assert entry.actor_type == "system"
      assert entry.old_state["claim_epoch"] == story.claim_epoch
    end

    test "leaves a renewed claim, a NULL-lease claim and a reported story alone" do
      tenant = fixture(:tenant)

      %{story: renewed} = claimed_story(tenant)

      %{story: legacy} = claimed_story(tenant)
      legacy = force(legacy, claimed_until: nil)

      %{story: reported} = claimed_story(tenant)
      reported = reported |> expire() |> force(agent_status: :reported_done)

      assert :ok = sweep()

      assert reload(renewed).agent_status == :assigned
      assert reload(renewed).claim_epoch == renewed.claim_epoch
      assert reload(legacy).agent_status == :assigned
      assert reload(legacy).claim_epoch == legacy.claim_epoch
      assert reload(reported).agent_status == :reported_done
      assert reload(reported).claim_epoch == reported.claim_epoch
    end

    test "sweeps every tenant, and each release is recorded under its own tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      %{story: story_a} = claimed_story(tenant_a)
      %{story: story_b} = claimed_story(tenant_b)
      story_a = expire(story_a)
      story_b = expire(story_b)

      assert :ok = sweep()

      assert reload(story_a).agent_status == :pending
      assert reload(story_b).agent_status == :pending
      assert [%AuditLog{tenant_id: tid_a}] = lease_expired_audit(story_a)
      assert [%AuditLog{tenant_id: tid_b}] = lease_expired_audit(story_b)
      assert tid_a == tenant_a.id
      assert tid_b == tenant_b.id
    end

    test "skips a tenant under a custody halt, which cannot renew" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      story = expire(story)

      {1, _} =
        from(t in Tenant, where: t.id == ^tenant.id)
        |> AdminRepo.update_all(set: [custody_halted_at: DateTime.utc_now()])

      assert :ok = sweep()

      assert reload(story).agent_status == :assigned
    end

    test "running twice releases once" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      story = expire(story)

      assert :ok = sweep()
      assert :ok = sweep()

      assert reload(story).claim_epoch == story.claim_epoch + 1
      assert [_one] = lease_expired_audit(story)
    end
  end

  describe "after a reclaim, the zombie is fenced" do
    setup do
      tenant = fixture(:tenant)
      %{story: story, agent: agent} = claimed_story(tenant)
      story = expire(story)
      :ok = sweep()
      %{tenant: tenant, story: story, agent: agent}
    end

    test "its start with the old epoch is refused", %{tenant: tenant, story: story, agent: agent} do
      assert {:error, :stale_claim_epoch} =
               Progress.start_story(tenant.id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )
    end

    test "a report carrying the old epoch is refused", %{tenant: tenant, story: story} do
      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      assert {:error, :stale_claim_epoch} =
               Progress.report_story(tenant.id, story.id,
                 agent_id: reviewer.id,
                 claim_epoch: story.claim_epoch
               )
    end

    test "its renewal with the old epoch is refused, and so is the fence check",
         %{tenant: tenant, story: story, agent: agent} do
      assert {:error, :not_claimed} =
               Progress.renew_claim(tenant.id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )

      assert {:error, :stale_claim_epoch} =
               Progress.check_claim_epoch(tenant.id, story.id, story.claim_epoch)
    end

    test "a re-claim by the same agent does not revive the old epoch",
         %{tenant: tenant, story: story, agent: agent} do
      {:ok, _} =
        Progress.contract_story(tenant.id, story.id, %{},
          agent_id: agent.id,
          skip_contract_check: true
        )

      {:ok, fresh} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      assert {:error, :stale_claim_epoch} =
               Progress.renew_claim(tenant.id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )

      assert :ok = Progress.check_claim_epoch(tenant.id, story.id, fresh.claim_epoch)
    end

    test "backfill-to-verified stays refused: the reclaim is not a launder path",
         %{tenant: tenant, story: story} do
      # The reclaimed row reads like never-dispatched work by its markers alone
      # (pending, no assigned agent, no dispatch). The stamped lifecycle_entered_at —
      # asserted in the perform/1 test — is the durable refusal, and it outlives the
      # retention-bounded audit rows.
      assert %DateTime{} = reload(story).lifecycle_entered_at
      assert reload(story).assigned_agent_id == nil

      assert {:error, :story_entered_lifecycle} =
               Progress.backfill_story(tenant.id, story.id, %{"reason" => "pre-loopctl work"})
    end
  end
end
