defmodule Loopctl.CoordinationClaimCollisionCodesTest do
  @moduledoc """
  #707 follow-up — the four causes of a 409 on `Coordination.claim/5` carry FOUR codes.

  They used to share `:already_claimed`, whose rendered body says "Do not retry the same
  ref; move on to other work." That advice is correct for a live peer claim and for the
  caller's own completed one, and WRONG for the other two: an expired-but-unswept lease
  is a ref nobody is working that is about to free itself, and a superseded ref is one
  nobody holds at all. A caller that moved on from either abandoned reachable work.

  The split also has to keep `claims_page/3` honest: that read lists the expired row and
  flags it `expired`, so before this the API told the caller one thing and the read told
  it the other.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim

  defp make_member(tenant, project, agent_id) do
    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent_id,
      agent_status: :assigned
    })
  end

  defp audit, do: [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: "agent:w"]

  defp setup_member do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
    make_member(tenant, project, agent_id)
    %{tenant: tenant, project: project, agent_id: agent_id}
  end

  defp claim!(tenant, agent_id, project, ref) do
    {:ok, claim} =
      Coordination.claim(tenant.id, agent_id, project.id, ref, role: :agent, audit: audit())

    claim
  end

  # Age the lease into the past rather than sleeping: the guard is a timestamp
  # comparison, so this exercises it exactly and keeps the suite async.
  defp expire_lease!(claim) do
    AdminRepo.update_all(
      from(c in ChannelClaim, where: c.id == ^claim.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
    )
  end

  describe "a live peer claim -> :already_claimed (move on is correct)" do
    test "a second agent racing an open ref is told the ref is taken" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      claim!(tenant, agent_a, project, "handoff:repo#1")

      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent_b, project.id, "handoff:repo#1",
                 role: :agent,
                 audit: audit()
               )
    end

    test "the owner re-claiming its own DONE ref is told the ref is taken, not reopened" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      claim!(tenant, agent, project, "handoff:repo#2")
      assert {:ok, _} = Coordination.done(tenant.id, agent, project.id, "handoff:repo#2", audit())

      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#2",
                 role: :agent,
                 audit: audit()
               )
    end
  end

  describe "an expired-but-unswept lease -> :claim_lease_expired (retry, do NOT move on)" do
    test "the OWNER re-claiming its own dead lease" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      claim!(tenant, agent, project, "handoff:repo#3") |> expire_lease!()

      assert {:error, :claim_lease_expired} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#3",
                 role: :agent,
                 audit: audit()
               )
    end

    test "a PEER hitting the same dead lease — same situation from the other side" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      claim!(tenant, agent_a, project, "handoff:repo#4") |> expire_lease!()

      assert {:error, :claim_lease_expired} =
               Coordination.claim(tenant.id, agent_b, project.id, "handoff:repo#4",
                 role: :agent,
                 audit: audit()
               )
    end

    test "the read and the write agree: the row is LISTED and flagged expired" do
      # This is the invariant the split exists to preserve. `claims_page/3` lists every
      # row that still holds the unique slot; the claim path must not describe that same
      # row as "taken, move on" while the read describes it as an expired husk.
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      claim!(tenant, agent, project, "handoff:repo#5") |> expire_lease!()

      assert {[listed], false} =
               Coordination.claims_page(tenant.id, project.id, ref: "handoff:repo#5")

      assert is_nil(listed.done_at)
      assert DateTime.compare(listed.lease_expires_at, DateTime.utc_now()) == :lt

      assert {:error, :claim_lease_expired} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#5",
                 role: :agent,
                 audit: audit()
               )
    end

    test "once the row is swept the ref claims cleanly — the retry the code advises works" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      claim = claim!(tenant, agent, project, "handoff:repo#6")
      expire_lease!(claim)

      AdminRepo.delete_all(from(c in ChannelClaim, where: c.id == ^claim.id))

      assert {:ok, fresh} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#6",
                 role: :agent,
                 audit: audit()
               )

      refute fresh.id == claim.id
    end
  end

  describe "the caller's own budget -> :claim_budget_exhausted (says nothing about the ref)" do
    test "an agent at its concurrent-claim ceiling is refused with its own code" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      for n <- 1..Coordination.max_concurrent_open_claims() do
        claim!(tenant, agent, project, "handoff:budget##{n}")
      end

      assert {:error, :claim_budget_exhausted} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:budget#free",
                 role: :agent,
                 audit: audit()
               )

      # And the ref really is free — a peer takes it, which is exactly why this must not
      # report as :already_claimed.
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent_b, project.id, "handoff:budget#free",
                 role: :agent,
                 audit: audit()
               )
    end
  end
end
