defmodule Loopctl.CoordinationClaimReadTest do
  @moduledoc """
  `Coordination.claims_page/3` (#707) — the NON-DESTRUCTIVE claim-state read that
  exists so no session has to learn "is this ref taken" by attempting a claim.

  The load-bearing property is not "it lists claims": it is that the listed set is
  exactly the set `claim/5` REFUSES, so "absent" and "claimable" are one set and a
  reader never has to probe. Read and write are asserted against each other on the same
  rows — including the expired-but-unswept row where they used to disagree.
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

  # Age the row rather than sleeping — the lifecycle is a timestamp comparison.
  defp expire!(claim) do
    Loopctl.AdminRepo.update_all(
      from(c in Coordination.ChannelClaim, where: c.id == ^claim.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
    )
  end

  describe "claims_page/3" do
    test "an open claim is listed; releasing it removes it from the read" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#812")

      assert {[listed], false} = Coordination.claims_page(tenant.id, project.id)
      assert listed.ref == "handoff:repo#812"
      assert listed.claimant_agent_id == agent_id

      assert {:ok, _} =
               Coordination.release(tenant.id, agent_id, project.id, "handoff:repo#812", audit())

      assert {[], false} = Coordination.claims_page(tenant.id, project.id)
    end

    test "a DONE claim stays listed — it is terminal, and it still excludes the handoff" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#813")

      assert {:ok, _} =
               Coordination.done(tenant.id, agent_id, project.id, "handoff:repo#813", audit())

      assert {[listed], false} = Coordination.claims_page(tenant.id, project.id)
      refute is_nil(listed.done_at)
    end

    test "an expired-but-unswept claim stays listed — because claim/5 still refuses it" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim = claim!(tenant, agent_id, project, "handoff:repo#814", lease_seconds: 1)
      expire!(claim)

      # The row no longer excludes the handoff but still holds the unique slot. Dropping
      # it from the read reports the ref free, then the next claim 409s (#707 review).
      assert {[listed], false} = Coordination.claims_page(tenant.id, project.id)
      assert listed.id == claim.id

      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent_id, project.id, "handoff:repo#814",
                 role: :agent,
                 audit: audit()
               )
    end

    test "OPEN claims are ordered ahead of terminal ones, so a truncated page keeps them" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()

      # The live claim is the OLDEST row: a plain newest-first page would drop it, which
      # is how a week of retained DONE rows could report a held ref as free.
      open = claim!(tenant, agent_id, project, "handoff:OPEN")
      claim!(tenant, agent_id, project, "handoff:done")

      assert {:ok, _} =
               Coordination.done(tenant.id, agent_id, project.id, "handoff:done", audit())

      expire!(claim!(tenant, agent_id, project, "handoff:stale"))

      assert {[first], true} = Coordination.claims_page(tenant.id, project.id, limit: 1)
      assert first.id == open.id
    end

    test "claiming swaps a ref out of the handoffs list and into this read" do
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
      assert {[], false} = Coordination.claims_page(tenant.id, project.id)

      claim!(tenant, agent_id, project, "handoff:repo#900")

      # Claimed: gone from handoffs, present here — the swap sessions used to probe for.
      assert [] == Coordination.directed_handoffs(tenant.id, project.id, %{})
      assert {[listed], false} = Coordination.claims_page(tenant.id, project.id)
      assert listed.ref == "handoff:repo#900"
    end

    test "ref: narrows to the point lookup a session about to claim wants" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#815")
      claim!(tenant, agent_id, project, "handoff:repo#816")

      assert {[one], false} =
               Coordination.claims_page(tenant.id, project.id, ref: "handoff:repo#815")

      assert one.ref == "handoff:repo#815"

      assert {[], false} =
               Coordination.claims_page(tenant.id, project.id, ref: "handoff:repo#999")
    end

    test "the page cap is reported, not silently applied" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      for n <- 1..3, do: claim!(tenant, agent_id, project, "handoff:repo##{n}")

      assert {[_, _], true} = Coordination.claims_page(tenant.id, project.id, limit: 2)
      assert {[_, _, _], false} = Coordination.claims_page(tenant.id, project.id, limit: 3)
    end

    test "tenant isolation: tenant A cannot see tenant B's claims" do
      %{tenant: tenant_a, project: project_a, agent_id: agent_a} = setup_member()
      %{tenant: tenant_b, project: project_b, agent_id: agent_b} = setup_member()

      claim!(tenant_a, agent_a, project_a, "handoff:shared#1")
      claim!(tenant_b, agent_b, project_b, "handoff:shared#1")

      assert {[a], false} = Coordination.claims_page(tenant_a.id, project_a.id)
      assert a.tenant_id == tenant_a.id

      # Tenant A asking for B's project: an empty page, never a 404 and never B's rows.
      assert {[], false} = Coordination.claims_page(tenant_a.id, project_b.id)
    end

    test "a malformed tenant_id or project_id is an empty page, never a cast error" do
      assert {[], false} = Coordination.claims_page("not-a-uuid", Ecto.UUID.generate())
      assert {[], false} = Coordination.claims_page(Ecto.UUID.generate(), "not-a-uuid")
      assert {[], false} = Coordination.claims_page(nil, nil)
    end

    test "a malformed ref is an empty page — never a 500, and never the whole channel" do
      %{tenant: tenant, project: project, agent_id: agent_id} = setup_member()
      claim!(tenant, agent_id, project, "handoff:repo#817")

      # A NUL byte is valid UTF-8 so Plug forwards it, and Postgres raises 22021 (a 500)
      # comparing it against `text`. Blank/non-binary refs must not widen the point
      # lookup back to the whole channel — the caller would read a stranger's claim.
      for bad <- [<<"handoff:", 0, "x">>, "", ["handoff:repo#817"]] do
        assert {[], false} = Coordination.claims_page(tenant.id, project.id, ref: bad)
      end
    end
  end

  describe "clamp_claims_limit/1" do
    test "clamps to the cap and defaults anything unparseable" do
      assert Coordination.clamp_claims_limit(5) == 5
      assert Coordination.clamp_claims_limit("5") == 5
      assert Coordination.clamp_claims_limit(10_000) == 200

      default = Coordination.default_claims_limit()
      assert Coordination.clamp_claims_limit(0) == default
      assert Coordination.clamp_claims_limit("x") == default
      assert Coordination.clamp_claims_limit(nil) == default
    end
  end
end
