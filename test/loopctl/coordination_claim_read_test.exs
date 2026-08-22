defmodule Loopctl.CoordinationClaimReadTest do
  @moduledoc """
  `Coordination.active_claims_page/3` (#707) — the NON-DESTRUCTIVE claim-state read
  that exists so no session has to learn "is this ref taken" by attempting a claim.

  The load-bearing property under test is not "it lists claims". It is that the set it
  lists is exactly the set `directed_handoffs_page/3` EXCLUDES, so a reader can answer
  "why is that handoff missing from my handoffs list" without probing. The two
  predicates are asserted against each other directly, on the same rows.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Coordination

  defp make_member(tenant, project, agent_id) do
    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent_id,
      agent_status: :assigned
    })
  end

  defp audit(label \\ "agent:worker-1") do
    [actor_type: "api_key", actor_id: Ecto.UUID.generate(), actor_label: label]
  end

  defp setup_member do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    agent_id = fixture(:agent, %{tenant_id: tenant.id}).id
    make_member(tenant, project, agent_id)
    %{tenant: tenant, project: project, agent_id: agent_id}
  end

  defp claim!(tenant, agent_id, project, ref, opts \\ []) do
    {:ok, claim} =
      Coordination.claim(
        tenant.id,
        agent_id,
        project.id,
        ref,
        Keyword.merge([role: :agent, audit: audit()], opts)
      )

    claim
  end

  describe "active_claims_page/3" do
    test "an open claim is listed; releasing it removes it from the read" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#812")

      assert {[listed], false} = Coordination.active_claims_page(tenant.id, project.id)
      assert listed.ref == "handoff:repo#812"
      assert listed.claimant_agent_id == agent_id
      assert is_nil(listed.done_at)

      assert {:ok, _} =
               Coordination.release(tenant.id, agent_id, project.id, "handoff:repo#812", audit())

      assert {[], false} = Coordination.active_claims_page(tenant.id, project.id)
    end

    test "a DONE claim stays listed — it is terminal, and it still excludes the handoff" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#813")

      assert {:ok, _} =
               Coordination.done(tenant.id, agent_id, project.id, "handoff:repo#813", audit())

      assert {[listed], false} = Coordination.active_claims_page(tenant.id, project.id)
      refute is_nil(listed.done_at)
    end

    test "a claim whose lease expired without completion is NOT listed — it reopened" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim = claim!(tenant, agent_id, project, "handoff:repo#814", lease_seconds: 1)

      # Move the lease into the past rather than sleeping: the predicate is a timestamp
      # comparison, so aging the row tests it exactly and keeps the suite async.
      Loopctl.AdminRepo.update_all(
        from(c in Coordination.ChannelClaim, where: c.id == ^claim.id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      assert {[], false} = Coordination.active_claims_page(tenant.id, project.id)
    end

    test "the listed set is exactly the set directed_handoffs_page/3 excludes" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()

      assert {:ok, _post, _} =
               Coordination.post(tenant.id, agent_id, :agent, %{
                 project_id: project.id,
                 key: "handoff:repo#900",
                 body: "do the thing",
                 session_id: "s-1",
                 audit: audit()
               })

      # Unclaimed: visible as a handoff, absent from the claims read.
      assert [_] = Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert {[], false} = Coordination.active_claims_page(tenant.id, project.id)

      claim!(tenant, agent_id, project, "handoff:repo#900")

      # Claimed: gone from handoffs, present in the claims read. This is the swap a
      # session used to have to discover by probing.
      assert [] == Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert {[listed], false} = Coordination.active_claims_page(tenant.id, project.id)
      assert listed.ref == "handoff:repo#900"
    end

    test "ref: narrows to the point lookup a session about to claim wants" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#815")
      claim!(tenant, agent_id, project, "handoff:repo#816")

      assert {[one], false} =
               Coordination.active_claims_page(tenant.id, project.id, ref: "handoff:repo#815")

      assert one.ref == "handoff:repo#815"

      assert {[], false} =
               Coordination.active_claims_page(tenant.id, project.id, ref: "handoff:repo#999")
    end

    test "the page cap is reported, not silently applied" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      for n <- 1..3, do: claim!(tenant, agent_id, project, "handoff:repo##{n}")

      assert {[_, _], true} = Coordination.active_claims_page(tenant.id, project.id, limit: 2)
      assert {[_, _, _], false} = Coordination.active_claims_page(tenant.id, project.id, limit: 3)
    end

    test "tenant isolation: tenant A cannot see tenant B's claims" do
      %{tenant: tenant_a, project: project_a, agent_id: agent_a} = setup_member()
      %{tenant: tenant_b, project: project_b, agent_id: agent_b} = setup_member()

      claim!(tenant_a, agent_a, project_a, "handoff:shared#1")
      claim!(tenant_b, agent_b, project_b, "handoff:shared#1")

      assert {[a], false} = Coordination.active_claims_page(tenant_a.id, project_a.id)
      assert a.tenant_id == tenant_a.id

      # Tenant A asking for tenant B's project gets an empty page, never a 404 and never
      # B's rows — the same no-oracle posture as the other coordination reads.
      assert {[], false} = Coordination.active_claims_page(tenant_a.id, project_b.id)
    end

    test "a malformed tenant_id or project_id is an empty page, never a cast error" do
      assert {[], false} = Coordination.active_claims_page("not-a-uuid", Ecto.UUID.generate())
      assert {[], false} = Coordination.active_claims_page(Ecto.UUID.generate(), "not-a-uuid")
      assert {[], false} = Coordination.active_claims_page(nil, nil)
    end
  end

  describe "clamp_active_claims_limit/1" do
    test "clamps to the cap and defaults anything unparseable" do
      assert Coordination.clamp_active_claims_limit(5) == 5
      assert Coordination.clamp_active_claims_limit("5") == 5
      assert Coordination.clamp_active_claims_limit(10_000) == 200

      assert Coordination.clamp_active_claims_limit(0) ==
               Coordination.default_active_claims_limit()

      assert Coordination.clamp_active_claims_limit("x") ==
               Coordination.default_active_claims_limit()

      assert Coordination.clamp_active_claims_limit(nil) ==
               Coordination.default_active_claims_limit()
    end
  end
end
