defmodule Loopctl.CoordinationClaimTest do
  @moduledoc """
  US-40.B1 — exactly-once handoff claim (`Coordination.claim/5`, `done/5`,
  `release/5`). The concurrent N-agent race (TC-40.B1.2), which needs genuinely
  independent DB sessions, lives in `coordination_claim_race_test.exs`.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim

  # Make an agent a writable member of a project (US-40.D3 gate): assign it a story.
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

  defp claim_audit_actions(tenant_id, entity_id) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "channel_claim",
        where: a.entity_id == ^entity_id,
        order_by: [asc: a.inserted_at],
        select: a.action
      )
    )
  end

  describe "claim/5" do
    test "TC-40.B1.1: first claim succeeds; a second agent claiming the same ref -> already_claimed" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent_a, project.id, "handoff:repo#812",
                 role: :agent,
                 audit: audit()
               )

      assert claim.tenant_id == tenant.id
      assert claim.project_id == project.id
      assert claim.claimant_agent_id == agent_a
      assert claim.ref == "handoff:repo#812"
      assert claim.done_at == nil
      assert claim.claimed_at
      assert claim.lease_expires_at

      # A DIFFERENT agent claiming the SAME ref loses on the unique index.
      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent_b, project.id, "handoff:repo#812",
                 role: :agent,
                 audit: audit("agent:worker-2")
               )

      # Exactly one row for the ref (tenant-scoped: the sandbox:false race test
      # commits a row with the same ref in a different tenant).
      assert AdminRepo.aggregate(
               from(c in ChannelClaim,
                 where: c.ref == "handoff:repo#812" and c.tenant_id == ^tenant.id
               ),
               :count
             ) == 1

      # The claim is audited as "claimed".
      assert claim_audit_actions(tenant.id, claim.id) == ["claimed"]
    end

    test "the same agent re-claiming its own held ref also -> already_claimed (exactly-once excludes claimant)" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())
    end

    test "lease_seconds sets a custom lease window" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 lease_seconds: 60,
                 audit: audit()
               )

      expected = DateTime.add(claim.claimed_at, 60, :second)
      assert_in_delta DateTime.to_unix(claim.lease_expires_at), DateTime.to_unix(expected), 2
    end

    test "AC-40.B1.7: a non-member agent (own tenant, no story assignment) is denied and writes nothing" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id}).id

      assert {:error, :not_found} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert AdminRepo.aggregate(
               from(c in ChannelClaim, where: c.tenant_id == ^tenant.id),
               :count
             ) == 0

      # Scope the audit count to THIS tenant: the concurrent race test
      # (coordination_claim_race_test.exs) runs sandbox:false and commits
      # channel_claim audit rows that have no tenant FK, so they orphan and a
      # global count would see them. This test's denial writes nothing for its
      # own tenant.
      assert AdminRepo.aggregate(
               from(a in AuditLog,
                 where: a.entity_type == "channel_claim" and a.tenant_id == ^tenant.id
               ),
               :count
             ) == 0
    end

    test "AC-40.B1.7: membership in ONE project does not grant a claim in a SIBLING project" do
      tenant = fixture(:tenant)
      p1 = fixture(:project, %{tenant_id: tenant.id})
      p2 = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, p1, agent)

      # Own project (p1) works...
      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, p1.id, "r", role: :agent, audit: audit())

      # ...sibling project (p2), no assignment, is denied.
      assert {:error, :not_found} =
               Coordination.claim(tenant.id, agent, p2.id, "r", role: :agent, audit: audit())
    end

    test "an elevated role (>= :user) bypasses the membership gate" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      agent = fixture(:agent, %{tenant_id: tenant.id}).id

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :user, audit: audit())
    end

    test "a missing / cross-tenant project returns {:error, :not_found}" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id}).id

      assert {:error, :not_found} =
               Coordination.claim(tenant_a.id, agent_a, project_b.id, "r",
                 role: :user,
                 audit: audit()
               )

      assert {:error, :not_found} =
               Coordination.claim(tenant_a.id, agent_a, Ecto.UUID.generate(), "r",
                 role: :user,
                 audit: audit()
               )
    end

    test "a foreign-tenant server-stamped agent returns {:error, :agent_not_found}" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id

      assert {:error, :agent_not_found} =
               Coordination.claim(tenant_a.id, agent_b, project_a.id, "r",
                 role: :user,
                 audit: audit()
               )
    end

    test "a blank ref is rejected with a changeset (422), never a claim" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:error, %Ecto.Changeset{} = cs} =
               Coordination.claim(tenant.id, agent, project.id, "   ",
                 role: :agent,
                 audit: audit()
               )

      assert %{ref: _} = errors_on(cs)
    end

    test "an over-length ref is rejected with a changeset, NOT already_claimed" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      too_long = String.duplicate("a", ChannelClaim.ref_max_length() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Coordination.claim(tenant.id, agent, project.id, too_long,
                 role: :agent,
                 audit: audit()
               )
    end
  end

  describe "done/5 and release/5" do
    test "TC-40.B1.3: done sets done_at; after release another agent can claim the ref again" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent_a, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      assert {:ok, done} = Coordination.done(tenant.id, agent_a, project.id, "r", audit())
      assert done.id == claim.id
      assert done.done_at

      # While the row still exists, B cannot claim.
      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent_b, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      # A releases -> the ref reopens.
      assert {:ok, released} = Coordination.release(tenant.id, agent_a, project.id, "r", audit())
      assert released.id == claim.id
      assert is_nil(AdminRepo.get(ChannelClaim, claim.id))

      # Now B can claim the same ref.
      assert {:ok, b_claim} =
               Coordination.claim(tenant.id, agent_b, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      assert b_claim.claimant_agent_id == agent_b

      # Full lifecycle audit trail on the original claim id.
      assert claim_audit_actions(tenant.id, claim.id) == ["claimed", "done", "released"]
    end

    test "TC-40.B1.4: a non-owner's done/release returns :not_found and leaves the claim untouched" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent_a, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      assert {:error, :not_found} =
               Coordination.done(tenant.id, agent_b, project.id, "r", audit())

      assert {:error, :not_found} =
               Coordination.release(tenant.id, agent_b, project.id, "r", audit())

      reloaded = AdminRepo.get(ChannelClaim, claim.id)
      refute is_nil(reloaded)
      assert is_nil(reloaded.done_at)
    end

    test "done/release on a nonexistent ref returns :not_found" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:error, :not_found} =
               Coordination.done(tenant.id, agent, project.id, "nope", audit())

      assert {:error, :not_found} =
               Coordination.release(tenant.id, agent, project.id, "nope", audit())
    end
  end

  describe "tenant isolation (TC-40.B1.6)" do
    test "a claim in tenant B is invisible/untouchable from tenant A" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id}).id
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id
      make_member(tenant_a, project_a, agent_a)
      make_member(tenant_b, project_b, agent_b)

      # B holds ref X in project_b.
      assert {:ok, b_claim} =
               Coordination.claim(tenant_b.id, agent_b, project_b.id, "X",
                 role: :agent,
                 audit: audit()
               )

      # A's read/done/release of ref X in ITS OWN project cannot see B's row.
      assert {:error, :not_found} =
               Coordination.done(tenant_a.id, agent_a, project_a.id, "X", audit())

      assert {:error, :not_found} =
               Coordination.release(tenant_a.id, agent_a, project_a.id, "X", audit())

      # A can independently claim ref X in its own project — no collision with B's.
      assert {:ok, a_claim} =
               Coordination.claim(tenant_a.id, agent_a, project_a.id, "X",
                 role: :agent,
                 audit: audit()
               )

      assert a_claim.id != b_claim.id
      # B's claim is untouched.
      refute is_nil(AdminRepo.get(ChannelClaim, b_claim.id))
    end
  end

  describe "ChannelClaim.create_changeset/2" do
    test "casts only :ref; a NUL byte in ref is rejected" do
      cs =
        ChannelClaim.create_changeset(
          %ChannelClaim{
            tenant_id: Ecto.UUID.generate(),
            project_id: Ecto.UUID.generate(),
            claimant_agent_id: Ecto.UUID.generate(),
            claimed_at: DateTime.utc_now(),
            lease_expires_at: DateTime.utc_now()
          },
          %{ref: "bad\0ref", tenant_id: "SPOOFED"}
        )

      refute cs.valid?
      assert %{ref: _} = errors_on(cs)
      # tenant_id in attrs is ignored (not cast) — the struct's stays.
      assert Ecto.Changeset.get_field(cs, :tenant_id) != "SPOOFED"
    end
  end
end
