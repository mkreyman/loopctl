defmodule Loopctl.Progress.ClaimLeaseCapTest do
  @moduledoc """
  #879 (US-44.5) — a claim taken for a runner dispatch carries a lease CAPPED at the
  dispatch deadline (`stories.claim_lease_cap`), and every other claim is untouched.

  Covers the context API: `claim_story/3` with and without `lease_until:`, `bulk_claim/4`,
  renewal (`renew_claim/3`) and the renewal grace (`grant_renewal_grace/2`) never passing the
  cap, every release clearing it, the `stories_claim_lease_within_cap` CHECK, and the column
  staying out of every `cast` list. That `Loopctl.Delivery.Placement` passes the cap is
  proved in `Loopctl.Delivery.PlacementTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.BulkOperations
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  defp contracted_story do
    agent = fixture(:agent, %{agent_type: :implementer})
    story = fixture(:story, %{tenant_id: agent.tenant_id, agent_status: :contracted})
    %{agent: agent, story: story, tenant_id: agent.tenant_id}
  end

  # A claim capped `seconds` from now, the shape `Placement` produces.
  defp capped_story(seconds) do
    %{agent: agent, story: story, tenant_id: tenant_id} = ctx = contracted_story()
    cap = DateTime.add(DateTime.utc_now(), seconds, :second)

    {:ok, claimed} =
      Progress.claim_story(tenant_id, story.id, agent_id: agent.id, lease_until: cap)

    Map.merge(ctx, %{story: claimed, cap: cap})
  end

  defp force(story, fields) do
    {1, _} = from(s in Story, where: s.id == ^story.id) |> AdminRepo.update_all(set: fields)
    AdminRepo.get!(Story, story.id)
  end

  defp reload(story), do: AdminRepo.get!(Story, story.id)

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)

  defp renew(%{agent: agent, story: story, tenant_id: tenant_id}) do
    Progress.renew_claim(tenant_id, story.id, agent_id: agent.id, claim_epoch: story.claim_epoch)
  end

  describe "claim_story/3 with lease_until: (AC-44.5.1)" do
    test "stores the cap and sets claimed_until to it" do
      %{story: claimed, cap: cap} = capped_story(4_500)

      assert claimed.claim_lease_cap == cap
      assert claimed.claimed_until == cap
      assert claimed.claim_epoch == 1

      persisted = reload(claimed)
      assert persisted.claim_lease_cap == cap
      assert persisted.claimed_until == cap
    end

    test "the cap is the lease even when it is later than the global lease" do
      far = Progress.claim_lease_seconds() + 900
      %{story: claimed, cap: cap} = capped_story(far)

      assert claimed.claimed_until == cap
      assert_in_delta seconds_from_now(claimed.claimed_until), far, 5
    end

    test "tenant isolation: another tenant cannot take a capped claim on the story" do
      %{agent: agent, story: story} = contracted_story()
      other_tenant = fixture(:tenant)
      cap = DateTime.add(DateTime.utc_now(), 4_500, :second)

      assert {:error, :not_found} =
               Progress.claim_story(other_tenant.id, story.id,
                 agent_id: agent.id,
                 lease_until: cap
               )

      untouched = reload(story)
      assert untouched.agent_status == :contracted
      assert untouched.claim_lease_cap == nil
      assert untouched.claimed_until == nil
    end
  end

  describe "every other claim path is unchanged (AC-44.5.4)" do
    test "claim_story/3 without lease_until keeps the global lease and a nil cap" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()

      {:ok, claimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)

      assert claimed.claim_lease_cap == nil
      assert_in_delta seconds_from_now(claimed.claimed_until), Progress.claim_lease_seconds(), 5
      assert reload(story).claim_lease_cap == nil
    end

    test "an uncapped claim WRITES a nil cap, so a stale one never rides into it" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()
      stale = force(story, claim_lease_cap: DateTime.add(DateTime.utc_now(), 60, :second))
      assert stale.claim_lease_cap != nil

      {:ok, claimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)

      assert claimed.claim_lease_cap == nil
      assert_in_delta seconds_from_now(claimed.claimed_until), Progress.claim_lease_seconds(), 5
    end

    test "bulk_claim/4 keeps the global lease and a nil cap, over a stale one too" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()
      force(story, claim_lease_cap: DateTime.add(DateTime.utc_now(), 60, :second))

      {:ok, [%{status: "success"}]} = BulkOperations.bulk_claim(tenant_id, [story.id], agent.id)

      claimed = reload(story)
      assert claimed.claim_lease_cap == nil
      assert_in_delta seconds_from_now(claimed.claimed_until), Progress.claim_lease_seconds(), 5
    end
  end

  describe "renewing a capped claim (AC-44.5.3)" do
    test "cannot pass the cap: claimed_until becomes the cap" do
      %{story: story, cap: cap} = ctx = capped_story(600)
      force(story, claimed_until: DateTime.add(DateTime.utc_now(), 30, :second))

      assert {:ok, renewed} = renew(ctx)
      assert renewed.claimed_until == cap
      assert renewed.claim_lease_cap == cap
      assert reload(story).claimed_until == cap
    end

    test "is the global lease from now when that is EARLIER than the cap" do
      far = Progress.claim_lease_seconds() + 3_600
      %{story: story, cap: cap} = ctx = capped_story(far)
      force(story, claimed_until: DateTime.add(DateTime.utc_now(), 30, :second))

      assert {:ok, renewed} = renew(ctx)
      assert DateTime.compare(renewed.claimed_until, cap) == :lt
      assert_in_delta seconds_from_now(renewed.claimed_until), Progress.claim_lease_seconds(), 5
      assert renewed.claim_lease_cap == cap
    end

    test "an uncapped claim still renews to the full global lease" do
      %{agent: agent, story: story, tenant_id: tenant_id} = contracted_story()
      {:ok, claimed} = Progress.claim_story(tenant_id, story.id, agent_id: agent.id)
      force(claimed, claimed_until: DateTime.add(DateTime.utc_now(), 30, :second))

      assert {:ok, renewed} = renew(%{agent: agent, story: claimed, tenant_id: tenant_id})
      assert_in_delta seconds_from_now(renewed.claimed_until), Progress.claim_lease_seconds(), 5
    end

    test "tenant isolation: another tenant's renewal is not_found and moves nothing" do
      %{story: story} = ctx = capped_story(600)
      before = reload(story).claimed_until
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} = renew(%{ctx | tenant_id: other_tenant.id})
      assert reload(story).claimed_until == before
    end
  end

  describe "grant_renewal_grace/2 is a renewal too" do
    test "extends a capped claim only to its cap, and an uncapped one to the floor" do
      %{story: capped, cap: cap, tenant_id: tenant_id} = capped_story(600)
      capped = force(capped, claimed_until: DateTime.add(DateTime.utc_now(), 30, :second))

      agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})
      plain = fixture(:story, %{tenant_id: tenant_id, agent_status: :contracted})
      {:ok, plain} = Progress.claim_story(tenant_id, plain.id, agent_id: agent.id)
      plain = force(plain, claimed_until: DateTime.add(DateTime.utc_now(), 30, :second))

      assert Progress.grant_renewal_grace(tenant_id) == 2

      assert reload(capped).claimed_until == cap

      assert_in_delta seconds_from_now(reload(plain).claimed_until),
                      Progress.renewal_grace_seconds(),
                      5
    end

    test "leaves a claim already AT its cap alone and does not count it" do
      %{story: story, cap: cap, tenant_id: tenant_id} = capped_story(600)

      assert Progress.grant_renewal_grace(tenant_id) == 0
      assert reload(story).claimed_until == cap
    end
  end

  describe "every release clears the cap (AC-44.5.5)" do
    test "force-unclaim" do
      %{story: story, tenant_id: tenant_id} = capped_story(600)

      {:ok, released} = Progress.force_unclaim_story(tenant_id, story.id)

      assert released.claim_lease_cap == nil
      assert released.claimed_until == nil
      assert reload(story).claim_lease_cap == nil
    end

    test "unclaim by the claimant" do
      %{agent: agent, story: story, tenant_id: tenant_id} = capped_story(600)

      {:ok, released} = Progress.unclaim_story(tenant_id, story.id, agent_id: agent.id)

      assert released.claim_lease_cap == nil
    end

    test "the reclaimer releasing an expired capped claim" do
      %{story: story, tenant_id: tenant_id} = capped_story(600)
      story = force(story, claimed_until: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:ok, released} =
               Progress.reclaim_expired_claim(tenant_id, story.id, story.claim_epoch)

      assert released.claim_lease_cap == nil
      assert reload(story).claim_lease_cap == nil
    end

    test "a rejection's auto-reset, single and bulk" do
      for reject <- [:single, :bulk] do
        %{story: story, tenant_id: tenant_id} = capped_story(600)
        story = force(story, agent_status: :reported_done, reported_done_at: DateTime.utc_now())
        orch = fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator})

        case reject do
          :single ->
            {:ok, _} =
              Progress.reject_story(tenant_id, story.id, %{"reason" => "Missing tests"},
                orchestrator_agent_id: orch.id
              )

          :bulk ->
            {:ok, [%{status: "success"}]} =
              BulkOperations.bulk_reject(
                tenant_id,
                [%{"story_id" => story.id, "reason" => "Missing tests"}],
                orch.id,
                verifier_lineage: []
              )
        end

        assert reload(story).claim_lease_cap == nil, "#{reject} reject kept the cap"
      end
    end

    test "claim_release_change/1 names the column, so no release can forget it" do
      story = %Story{claim_epoch: 3, claim_lease_cap: DateTime.utc_now()}
      assert %{claim_lease_cap: nil, claimed_until: nil} = Progress.claim_release_change(story)
    end
  end

  describe "the cap is absolute in the database" do
    test "a lease written past its cap violates stories_claim_lease_within_cap" do
      %{story: story, cap: cap} = capped_story(600)

      assert_raise Postgrex.Error, ~r/stories_claim_lease_within_cap/, fn ->
        force(story, claimed_until: DateTime.add(cap, 1, :second))
      end
    end
  end

  describe "the column is never cast" do
    test "neither changeset casts claim_lease_cap, so PATCH cannot lift or clear it" do
      %{story: story} = capped_story(600)
      attrs = %{"claim_lease_cap" => "2099-01-01T00:00:00Z", "title" => "renamed"}

      refute Map.has_key?(Story.update_changeset(story, attrs).changes, :claim_lease_cap)
      refute Map.has_key?(Story.create_changeset(%Story{}, attrs).changes, :claim_lease_cap)
    end
  end
end
