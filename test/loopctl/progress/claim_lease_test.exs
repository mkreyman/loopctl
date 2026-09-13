defmodule Loopctl.Progress.ClaimLeaseTest do
  @moduledoc """
  #803 — a story claim carries a lease (`claimed_until`) and a fence (`claim_epoch`).

  Covers the context API: the claim writes both, `renew_claim/3` extends the lease only
  for the claimant holding the current epoch, every release bumps the epoch,
  `check_claim_epoch/3` is the fence the runner channel requires, start/report accept
  the epoch optionally, and `reclaim_expired_claim/3` re-checks everything under the row
  lock. The sweep itself is covered in `ReclaimExpiredClaimsWorkerTest`; the
  cross-session exclusivity of claim and reclaim is proved in `ClaimLockTest`, because
  the SQL sandbox serialises an async test's processes onto one connection.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  defp contracted_story do
    agent = fixture(:agent, %{agent_type: :implementer})
    story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})
    %{agent: agent, story: story, tenant_id: agent.tenant_id}
  end

  defp claimed_story do
    %{agent: agent, story: story, tenant_id: tenant_id} = ctx = contracted_story()
    {:ok, claimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)
    Map.put(ctx, :story, claimed)
  end

  defp force(story, fields) do
    {1, _} = from(s in Story, where: s.id == ^story.id) |> AdminRepo.update_all(set: fields)
    AdminRepo.get!(Story, story.id)
  end

  defp audit_actions(story) do
    from(a in AuditLog,
      where: a.tenant_id == ^story.tenant_id and a.entity_id == ^story.id,
      select: a.action
    )
    |> AdminRepo.all()
  end

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)

  describe "claim_story/3" do
    test "sets a lease of claim_lease_seconds/0 and increments the epoch" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()
      assert story.claim_epoch == 0
      assert story.claimed_until == nil

      {:ok, claimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)

      assert claimed.claim_epoch == 1
      assert_in_delta seconds_from_now(claimed.claimed_until), Progress.claim_lease_seconds(), 5

      persisted = AdminRepo.get!(Story, story.id)
      assert persisted.claim_epoch == 1
      assert persisted.claimed_until == claimed.claimed_until
    end

    test "the default lease is long: 24 hours" do
      assert Progress.claim_lease_seconds() == 86_400
    end

    test "each claim takes the NEXT epoch, so a re-claim after a release never reuses one" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      {:ok, released} = Progress.unclaim_story(tenant_id, story.id, agent_id: agent.id)
      assert released.claim_epoch == 2

      {:ok, _} =
        Progress.contract_story(tenant_id, story.id, %{},
          agent_id: agent.id,
          skip_contract_check: true
        )

      {:ok, reclaimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)
      assert reclaimed.claim_epoch == 3
    end
  end

  describe "renew_claim/3" do
    test "the claimant with the current epoch extends the lease from now" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), 60, :second))

      assert {:ok, renewed} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )

      assert_in_delta seconds_from_now(renewed.claimed_until), Progress.claim_lease_seconds(), 5
      assert renewed.claim_epoch == story.claim_epoch
      assert "claim_renewed" in audit_actions(story)
    end

    test "works on an implementing story" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, agent_status: :implementing)

      assert {:ok, _} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )
    end

    test "a stale epoch is refused and the lease is untouched" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      assert {:error, :stale_claim_epoch} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch - 1
               )

      assert AdminRepo.get!(Story, story.id).claimed_until == story.claimed_until
    end

    test "a missing epoch is refused as stale, never treated as a wildcard" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      assert {:error, :stale_claim_epoch} =
               Progress.renew_claim(tenant_id, story.id, agent_id: agent.id)
    end

    test "a caller that is not the assigned agent is refused" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      other = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

      assert {:error, :not_claimant} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: other.id,
                 claim_epoch: story.claim_epoch
               )

      assert {:error, :not_claimant} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: nil,
                 claim_epoch: story.claim_epoch
               )
    end

    test "a story that is not held by a claim is refused" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()

      assert {:error, :not_claimed} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )

      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      reported = force(story, agent_status: :reported_done)

      assert {:error, :not_claimed} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: reported.claim_epoch
               )
    end

    test "renewing a claim made before leases existed gives it one" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: nil)

      assert {:ok, %Story{claimed_until: %DateTime{}}} =
               Progress.renew_claim(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )
    end

    test "tenant isolation: another tenant cannot renew the claim" do
      %{agent: agent, story: story} = claimed_story()
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.renew_claim(other_tenant.id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )
    end
  end

  describe "every release bumps the epoch" do
    test "unclaim and force-unclaim clear the lease and take the next epoch" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      {:ok, unclaimed} = Progress.unclaim_story(tenant_id, story.id, agent_id: agent.id)
      assert unclaimed.claim_epoch == story.claim_epoch + 1
      assert unclaimed.claimed_until == nil

      %{story: story, tenant_id: tenant_id} = claimed_story()
      {:ok, forced} = Progress.force_unclaim_story(tenant_id, story.id)
      assert forced.claim_epoch == story.claim_epoch + 1
      assert forced.claimed_until == nil
    end

    test "a rejection's auto-reset bumps the epoch, single and bulk" do
      for reject <- [:single, :bulk] do
        %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
        story = force(story, agent_status: :reported_done, reported_done_at: DateTime.utc_now())
        orch = fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator})
        assert orch.id != agent.id

        case reject do
          :single ->
            {:ok, _} =
              Progress.reject_story(tenant_id, story.id, %{"reason" => "Missing tests"},
                orchestrator_agent_id: orch.id
              )

          :bulk ->
            {:ok, [%{status: "success"}]} =
              Loopctl.BulkOperations.bulk_reject(
                tenant_id,
                [%{"story_id" => story.id, "reason" => "Missing tests"}],
                orch.id,
                verifier_lineage: []
              )
        end

        reset = AdminRepo.get!(Story, story.id)
        assert reset.agent_status == :pending, "#{reject} reject did not auto-reset"
        assert reset.claim_epoch == story.claim_epoch + 1, "#{reject} reject kept the epoch"
        assert reset.claimed_until == nil
      end
    end

    test "a bulk claim writes the same lease and epoch as a single claim" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_claim(tenant_id, [story.id], agent.id)

      claimed = AdminRepo.get!(Story, story.id)
      assert claimed.claim_epoch == 1
      assert_in_delta seconds_from_now(claimed.claimed_until), Progress.claim_lease_seconds(), 5
    end

    test "force-unclaim of an already-pending story does not bump" do
      %{story: story, tenant_id: tenant_id} = contracted_story()
      story = force(story, agent_status: :pending)
      {:ok, same} = Progress.force_unclaim_story(tenant_id, story.id)
      assert same.claim_epoch == story.claim_epoch
    end
  end

  describe "check_claim_epoch/3" do
    test "accepts the current epoch and refuses any other" do
      %{story: story, tenant_id: tenant_id} = claimed_story()

      assert :ok = Progress.check_claim_epoch(tenant_id, story.id, story.claim_epoch)

      assert {:error, :stale_claim_epoch} =
               Progress.check_claim_epoch(tenant_id, story.id, story.claim_epoch - 1)

      assert {:error, :stale_claim_epoch} =
               Progress.check_claim_epoch(tenant_id, story.id, story.claim_epoch + 1)
    end

    test "a released claim's epoch no longer passes" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      {:ok, _} = Progress.force_unclaim_story(tenant_id, story.id)

      assert {:error, :stale_claim_epoch} =
               Progress.check_claim_epoch(tenant_id, story.id, story.claim_epoch)
    end

    test "tenant isolation: another tenant's lookup is not_found, never ok" do
      %{story: story} = claimed_story()
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.check_claim_epoch(other_tenant.id, story.id, story.claim_epoch)
    end
  end

  describe "optional claim_epoch on start and report" do
    test "start refuses a stale epoch and leaves the story assigned" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      assert {:error, :stale_claim_epoch} =
               Progress.start_story(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch - 1
               )

      assert AdminRepo.get!(Story, story.id).agent_status == :assigned
    end

    test "start accepts the current epoch, and behaves as before when it is absent" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      assert {:ok, %Story{agent_status: :implementing}} =
               Progress.start_story(tenant_id, story.id,
                 agent_id: agent.id,
                 claim_epoch: story.claim_epoch
               )

      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()

      assert {:ok, %Story{agent_status: :implementing}} =
               Progress.start_story(tenant_id, story.id, agent_id: agent.id)
    end

    test "report refuses a stale epoch, and accepts the current one" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, agent_status: :implementing)
      reviewer = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

      assert {:error, :stale_claim_epoch} =
               Progress.report_story(tenant_id, story.id,
                 agent_id: reviewer.id,
                 claim_epoch: story.claim_epoch + 1
               )

      assert AdminRepo.get!(Story, story.id).agent_status == :implementing

      assert {:ok, %Story{agent_status: :reported_done}} =
               Progress.report_story(tenant_id, story.id,
                 agent_id: reviewer.id,
                 claim_epoch: story.claim_epoch
               )
    end
  end

  describe "reclaim_expired_claim/3" do
    test "releases an expired claim like force-unclaim, stamped, audited, epoch bumped" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:ok, released} =
               Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch)

      assert released.agent_status == :pending
      assert released.assigned_agent_id == nil
      assert released.assigned_at == nil
      assert released.claimed_until == nil
      assert released.claim_epoch == story.claim_epoch + 1
      assert %DateTime{} = released.lifecycle_entered_at
      assert "claim_lease_expired" in audit_actions(story)
    end

    test "a lease renewed after the sweep read it is left alone" do
      %{agent: agent, story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))
      epoch_the_sweep_read = story.claim_epoch

      {:ok, _} =
        Progress.renew_claim(tenant_id, story.id,
          agent_id: agent.id,
          claim_epoch: story.claim_epoch
        )

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, story.id, epoch_the_sweep_read)

      assert AdminRepo.get!(Story, story.id).agent_status == :assigned
    end

    test "a different claim than the one the sweep read is left alone, even with an expired lease" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch - 1)

      assert AdminRepo.get!(Story, story.id).agent_status == :assigned
    end

    test "a NULL lease, a future lease and a reported story are never reclaimed" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      no_lease = force(story, claimed_until: nil)

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, no_lease.id, no_lease.claim_epoch)

      %{story: story, tenant_id: tenant_id} = claimed_story()

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch)

      %{story: story, tenant_id: tenant_id} = claimed_story()

      reported =
        force(story,
          agent_status: :reported_done,
          claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, reported.id, reported.claim_epoch)
    end

    test "running it twice releases once" do
      %{story: story, tenant_id: tenant_id} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:ok, _} = Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch)

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch)

      assert AdminRepo.get!(Story, story.id).claim_epoch == story.claim_epoch + 1
    end

    test "tenant isolation: another tenant cannot reclaim the story" do
      %{story: story} = claimed_story()
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Progress.reclaim_expired_claim(other_tenant.id, story.id, story.claim_epoch)

      assert AdminRepo.get!(Story, story.id).agent_status == :assigned
    end
  end
end
