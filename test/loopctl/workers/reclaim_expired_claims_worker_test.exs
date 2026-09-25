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
  alias Loopctl.Tenants
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

    test "stories it will never release cannot fill the bounded batch and starve a real expiry" do
      # The sweep reads at most batch_size/0 candidates, oldest lease first. Stories in
      # review, in a halted tenant, or in a suspended tenant are refused under the lock on
      # every run and stay that way — so if the READ admitted them, enough old ones would
      # take every slot on every run and a genuinely expired claim behind them would never
      # be released.
      halted_tenant = fixture(:tenant)
      suspended_tenant = fixture(:tenant)
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      halted_agent = fixture(:agent, %{tenant_id: halted_tenant.id, agent_type: :implementer})

      suspended_agent =
        fixture(:agent, %{tenant_id: suspended_tenant.id, agent_type: :implementer})

      old_lease = DateTime.add(DateTime.utc_now(), -3_600, :second)
      # Each kind ALONE is enough to fill the batch, so each exclusion is proved on its own.
      overflow = ReclaimExpiredClaimsWorker.batch_size() + 1

      for _ <- 1..overflow do
        tenant.id
        |> then(&fixture(:story, %{tenant_id: &1, agent_status: :implementing}))
        |> force(
          assigned_agent_id: agent.id,
          claimed_until: old_lease,
          review_requested_at: DateTime.utc_now()
        )

        halted_tenant.id
        |> then(&fixture(:story, %{tenant_id: &1, agent_status: :assigned}))
        |> force(assigned_agent_id: halted_agent.id, claimed_until: old_lease)

        suspended_tenant.id
        |> then(&fixture(:story, %{tenant_id: &1, agent_status: :assigned}))
        |> force(assigned_agent_id: suspended_agent.id, claimed_until: old_lease)
      end

      {1, _} =
        from(t in Tenant, where: t.id == ^halted_tenant.id)
        |> AdminRepo.update_all(set: [custody_halted_at: DateTime.utc_now()])

      {:ok, _} = Tenants.suspend_tenant(suspended_tenant)

      %{story: real} = claimed_story(tenant)
      real = expire(real)

      assert :ok = sweep()

      assert reload(real).agent_status == :pending
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

  describe "candidates/2" do
    # #877 review round 2, finding 2. Ranked oldest lease first ACROSS tenants, a tenant whose
    # releases keep failing (a broken chain refuses every one) kept its oldest leases at the
    # head of every run, and with more of them than the batch it starved every other tenant's
    # reclaim for good. Ranked within each tenant, every tenant's oldest is taken before any
    # tenant's second.
    test "one tenant's older leases cannot fill the batch ahead of another tenant's" do
      stuck = fixture(:tenant)
      other = fixture(:tenant)
      now = DateTime.utc_now()

      stuck_ids =
        for age <- [3_600, 3_000, 2_400] do
          %{story: story} = claimed_story(stuck)
          force(story, claimed_until: DateTime.add(now, -age, :second)).id
        end

      %{story: waiting} = claimed_story(other)
      waiting = force(waiting, claimed_until: DateTime.add(now, -60, :second))

      # A limit smaller than the stuck tenant's backlog: ranked globally, both slots are its.
      assert [first, second] =
               now
               |> ReclaimExpiredClaimsWorker.candidates(2)
               |> Enum.filter(&(&1.tenant_id in [stuck.id, other.id]))

      assert {first.tenant_id, first.id} == {stuck.id, hd(stuck_ids)}
      assert {second.tenant_id, second.id} == {other.id, waiting.id}
      assert second.claim_epoch == waiting.claim_epoch
    end
  end

  describe "a story handed to review" do
    defp in_review(tenant) do
      %{story: story, agent: agent} = claimed_story(tenant)
      {:ok, _} = Progress.start_story(tenant.id, story.id, agent_id: agent.id)
      {:ok, reviewed} = Progress.request_review(tenant.id, story.id, agent_id: agent.id)
      %{story: reviewed, agent: agent}
    end

    test "is not reclaimed when its lease runs out, and the reviewer's report succeeds" do
      tenant = fixture(:tenant)
      %{story: story} = in_review(tenant)
      assert %DateTime{} = story.review_requested_at
      story = expire(story)

      assert :ok = sweep()

      assert reload(story).agent_status == :implementing
      assert reload(story).claim_epoch == story.claim_epoch

      reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      assert {:ok, %Story{agent_status: :reported_done}} =
               Progress.report_story(tenant.id, story.id,
                 agent_id: reviewer.id,
                 claim_epoch: story.claim_epoch
               )
    end

    test "the locked re-check refuses it too, even when the sweep's read predated the request" do
      tenant = fixture(:tenant)
      %{story: story} = in_review(tenant)
      story = expire(story)

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant.id, story.id, story.claim_epoch)
    end

    test "a renewal after the request does not re-arm the lease" do
      tenant = fixture(:tenant)
      %{story: story, agent: agent} = in_review(tenant)

      {:ok, _} =
        Progress.renew_claim(tenant.id, story.id,
          agent_id: agent.id,
          claim_epoch: story.claim_epoch
        )

      story = expire(story)
      assert :ok = sweep()

      assert reload(story).agent_status == :implementing
    end

    test "a second request keeps the first timestamp, and a release clears the marker" do
      tenant = fixture(:tenant)
      %{story: story, agent: agent} = in_review(tenant)

      {:ok, again} = Progress.request_review(tenant.id, story.id, agent_id: agent.id)
      assert again.review_requested_at == story.review_requested_at

      {:ok, released} = Progress.force_unclaim_story(tenant.id, story.id)
      assert released.review_requested_at == nil
    end
  end

  describe "custody halts" do
    defp halt(tenant) do
      {1, _} =
        from(t in Tenant, where: t.id == ^tenant.id)
        |> AdminRepo.update_all(set: [custody_halted_at: DateTime.utc_now()])

      :ok
    end

    test "a halt that lands after the sweep read is refused under the lock" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      story = expire(story)
      :ok = halt(tenant)

      assert {:error, :custody_halted} =
               Progress.reclaim_expired_claim(tenant.id, story.id, story.claim_epoch)

      assert reload(story).agent_status == :assigned
    end

    test "a lease that ran out during a halt survives the first sweep after the clear" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      :ok = halt(tenant)
      story = expire(story)

      {:ok, _} = Tenants.clear_custody_halt(tenant.id)
      assert :ok = sweep()

      survived = reload(story)
      assert survived.agent_status == :assigned

      assert_in_delta DateTime.diff(survived.claimed_until, DateTime.utc_now(), :second),
                      Progress.renewal_grace_seconds(),
                      5

      # Once the grace itself has run out with no renewal, the claim is reclaimable.
      expire(story)
      assert :ok = sweep()
      assert reload(story).agent_status == :pending
    end

    test "the clear moves only short leases, never NULL ones, and not on an unhalted tenant" do
      tenant = fixture(:tenant)
      %{story: long} = claimed_story(tenant)
      long = force(long, claimed_until: DateTime.add(DateTime.utc_now(), 10 * 86_400, :second))
      %{story: legacy} = claimed_story(tenant)
      legacy = force(legacy, claimed_until: nil)
      %{story: short} = claimed_story(tenant)
      short = expire(short)

      # Not halted: a retried clear changes no lease.
      {:ok, _} = Tenants.clear_custody_halt(tenant.id)
      assert reload(short).claimed_until == short.claimed_until

      :ok = halt(tenant)
      {:ok, _} = Tenants.clear_custody_halt(tenant.id)

      assert reload(long).claimed_until == long.claimed_until
      assert reload(legacy).claimed_until == nil
      assert DateTime.compare(reload(short).claimed_until, DateTime.utc_now()) == :gt
    end

    test "tenant isolation: clearing one tenant's halt extends no other tenant's leases" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      %{story: story_b} = claimed_story(tenant_b)
      story_b = expire(story_b)

      :ok = halt(tenant_a)
      {:ok, _} = Tenants.clear_custody_halt(tenant_a.id)

      assert reload(story_b).claimed_until == story_b.claimed_until
    end
  end

  describe "tenants that are not active" do
    defp set_status(tenant, status) do
      {1, _} =
        from(t in Tenant, where: t.id == ^tenant.id)
        |> AdminRepo.update_all(set: [status: status])

      AdminRepo.get!(Tenant, tenant.id)
    end

    test "a suspended tenant's expired lease is not reclaimed by the sweep" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      {:ok, _} = Tenants.suspend_tenant(tenant)
      story = expire(story)

      assert :ok = sweep()

      assert reload(story).agent_status == :assigned
      assert reload(story).claim_epoch == story.claim_epoch
    end

    test "the locked re-check refuses every non-active status, even when the sweep read it active" do
      for status <- [:suspended, :deactivated, :pending_enrollment] do
        tenant = fixture(:tenant)
        %{story: story} = claimed_story(tenant)
        story = expire(story)
        set_status(tenant, status)

        assert {:error, :tenant_inactive} =
                 Progress.reclaim_expired_claim(tenant.id, story.id, story.claim_epoch),
               "#{status} tenant was reclaimed"

        assert reload(story).agent_status == :assigned
      end
    end

    test "re-activation grants a full lease of grace; once that runs out the claim is reclaimable" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      {:ok, suspended} = Tenants.suspend_tenant(tenant)
      story = expire(story)

      {:ok, _} = Tenants.activate_tenant(suspended)
      assert :ok = sweep()

      survived = reload(story)
      assert survived.agent_status == :assigned

      assert_in_delta DateTime.diff(survived.claimed_until, DateTime.utc_now(), :second),
                      Progress.renewal_grace_seconds(),
                      5

      expire(story)
      assert :ok = sweep()
      assert reload(story).agent_status == :pending
    end

    test "activating an already-active tenant grants nothing, even from a stale suspended struct" do
      tenant = fixture(:tenant)
      %{story: story} = claimed_story(tenant)
      story = expire(story)

      {:ok, _} = Tenants.activate_tenant(tenant)
      assert reload(story).claimed_until == story.claimed_until

      # The caller's struct says :suspended, the row says :active: the LOCKED row decides.
      {:ok, _} = Tenants.activate_tenant(%{tenant | status: :suspended})
      assert reload(story).claimed_until == story.claimed_until
    end

    test "tenant isolation: activating one tenant extends no other tenant's leases" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      %{story: story_b} = claimed_story(tenant_b)
      story_b = expire(story_b)

      {:ok, suspended_a} = Tenants.suspend_tenant(tenant_a)
      {:ok, _} = Tenants.activate_tenant(suspended_a)

      assert reload(story_b).claimed_until == story_b.claimed_until
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
