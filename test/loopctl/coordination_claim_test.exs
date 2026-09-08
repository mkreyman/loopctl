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
  alias Loopctl.Security.SecretDenylist

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

  defp claim_audit_metadata(tenant_id, entity_id) do
    AdminRepo.all(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_type == "channel_claim",
        where: a.entity_id == ^entity_id,
        order_by: [asc: a.inserted_at],
        select: a.metadata
      )
    )
  end

  # Age a live claim past its lease without waiting one out.
  defp expire_claim(claim) do
    claim
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> AdminRepo.update!()
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

    test "the OWNER re-claiming its own still-active ref is idempotent -> {:ok, same claim, :already_held}" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, first} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      # A lost-response retry by the TRUE owner returns the SAME claim, not a 409 —
      # closing the dropped-handoff window (the owner would otherwise be told "another
      # agent owns this, move on" and abandon a handoff it actually holds). #779: the
      # marker is a THIRD tuple element, because under a shared agent_id this branch is
      # also what a PEER SESSION's live claim comes back as.
      assert {:ok, second, :already_held} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert second.id == first.id
      assert second.done_at == nil
      # The ORIGINAL claimed_at, not a refreshed one — that timestamp is what tells a
      # reader the claim is minutes old and therefore not the one it just made.
      assert second.claimed_at == first.claimed_at

      # Still exactly one row, and NO second "claimed" audit entry (nothing changed).
      assert AdminRepo.aggregate(
               from(c in ChannelClaim, where: c.ref == "r" and c.tenant_id == ^tenant.id),
               :count
             ) == 1

      assert claim_audit_actions(tenant.id, first.id) == ["claimed"]
    end

    test "a DIFFERENT agent re-claiming the same active ref still -> already_claimed" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent_a, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      assert {:error, :already_claimed} =
               Coordination.claim(tenant.id, agent_b, project.id, "r",
                 role: :agent,
                 audit: audit()
               )
    end

    test "the OWNER re-claiming its OWN already-DONE ref -> already_claimed (not reopened)" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:ok, _} = Coordination.done(tenant.id, agent, project.id, "r", audit())

      # Once the owner has marked the ref done, re-claiming does NOT idempotently
      # reopen it — the completed slot is still occupied.
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
    test "TC-40.B1.3: done sets done_at; after release of an OPEN claim another agent can claim the ref again" do
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent_a, project.id, "r",
                 role: :agent,
                 audit: audit()
               )

      # A releases while STILL OPEN -> the ref reopens.
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

      # B marks done — done is terminal.
      assert {:ok, done} = Coordination.done(tenant.id, agent_b, project.id, "r", audit())
      assert done.id == b_claim.id
      assert done.done_at

      # Full lifecycle audit trail on B's claim.
      assert claim_audit_actions(tenant.id, b_claim.id) == ["claimed", "done"]
    end

    test "releasing a DONE claim is refused (terminal guarantee)" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:ok, _} = Coordination.done(tenant.id, agent, project.id, "r", audit())

      # A DONE claim is terminal and CANNOT be released.
      assert {:error, :already_claimed} =
               Coordination.release(tenant.id, agent, project.id, "r", audit())

      # The row is still there.
      refute is_nil(AdminRepo.get(ChannelClaim, claim.id))
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

  describe "the advisory session discriminator (issue #779)" do
    # THE INCIDENT (KB 8d9156ca / b447b16b): two machines, ONE agent key. The second
    # session re-claimed a ref its peer already held, got a plain success with its own
    # claimant_agent_id, wrote "one claim - mine" and shipped a duplicate PR.
    test "a PEER SESSION's live claim comes back marked already_held, with the ORIGINAL claimed_at and the PEER's session" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, first} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#488",
                 role: :agent,
                 session_id: "session-minis",
                 host: "minis",
                 audit: audit()
               )

      assert first.claimed_by_session == "session-minis"
      assert first.claimed_by_host == "minis"

      # A DIFFERENT session on the SAME agent key. Same call, same key, same ref.
      assert {:ok, seen, :already_held} =
               Coordination.claim(tenant.id, agent, project.id, "handoff:repo#488",
                 role: :agent,
                 session_id: "session-mac-mini",
                 host: "mac-mini",
                 audit: audit()
               )

      # Everything the second session needs to tell this is not its own claim.
      assert seen.id == first.id
      assert seen.claimed_at == first.claimed_at
      assert seen.claimed_by_session == "session-minis"
      assert seen.claimed_by_host == "minis"
      # And the re-claim did NOT restamp the row with the caller's session.
      assert AdminRepo.get(ChannelClaim, first.id).claimed_by_session == "session-minis"
    end

    test "a FRESH claim is a 2-tuple; only the idempotent branch carries :already_held" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, %ChannelClaim{}} =
               Coordination.claim(tenant.id, agent, project.id, "fresh",
                 role: :agent,
                 session_id: "s1",
                 audit: audit()
               )
    end

    test "done from a DIFFERENT session is refused and marks nothing done" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, :claim_session_mismatch} =
               Coordination.done(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-b"
               )

      assert is_nil(AdminRepo.get(ChannelClaim, claim.id).done_at)
      assert claim_audit_actions(tenant.id, claim.id) == ["claimed"]
    end

    # KB 07f5e839: this is the one that DELETED a peer's live work.
    test "release from a DIFFERENT session is refused and the peer's row survives" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, :claim_session_mismatch} =
               Coordination.release(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-b"
               )

      refute is_nil(AdminRepo.get(ChannelClaim, claim.id))
    end

    test "the SAME session may done and release its own claim" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r1",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:ok, done} =
               Coordination.done(tenant.id, agent, project.id, "r1", audit(),
                 session_id: "session-a"
               )

      assert done.done_at

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r2",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:ok, _} =
               Coordination.release(tenant.id, agent, project.id, "r2", audit(),
                 session_id: "session-a"
               )
    end

    # KB 9c3e14a1 warns that session-scoped ownership strands a session that crashed and
    # relaunched under a new session id. `force` is the answer, and it must be one call.
    test "force: true clears the refusal for a session that restarted under a new id" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-before-crash",
                 audit: audit()
               )

      assert {:ok, done} =
               Coordination.done(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-after-relaunch",
                 force: true
               )

      assert done.done_at
    end

    # The guard's whole value is the RECORDED failure — a forced override used to write
    # an audit entry byte-identical to the owner ending its own work, so KB 07f5e839's
    # incident stayed unattributable after the row was deleted.
    test "a FORCED cross-session release is recorded as forced; a self-release is not" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      for {ref, caller, opts, forced} <- [
            {"forced", "session-b", [force: true], true},
            {"own", "session-a", [], false}
          ] do
        assert {:ok, claim} =
                 Coordination.claim(tenant.id, agent, project.id, ref,
                   role: :agent,
                   session_id: "session-a",
                   audit: audit()
                 )

        # Passed in the AUDIT position on purpose: `audit` and `opts` are adjacent
        # optional keyword lists, so a call written this way used to disable the guard
        # AND write the two keys into the entry as actor context. They are routed by
        # KEY now, so this shape must behave exactly like the arity-6 one.
        assert {:ok, _} =
                 Coordination.release(
                   tenant.id,
                   agent,
                   project.id,
                   ref,
                   audit() ++ [session_id: caller] ++ opts
                 )

        assert [_claimed, released] = claim_audit_metadata(tenant.id, claim.id)
        assert released["forced"] == forced
        assert released["caller_session"] == caller
        assert released["claimed_by_session"] == "session-a"
      end
    end

    # A refusal writes NO audit row at all, so telemetry is the only way an operator
    # sees a session probing its peers' claims.
    test "the refusal fires the claim_session_guard telemetry, so it is not silent" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      test_pid = self()
      handler_id = "claim-session-guard-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :claim_session_guard],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant.id, do: send(test_pid, {:guard, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, :claim_session_mismatch} =
               Coordination.release(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-b"
               )

      assert_received {:guard, %{count: 1}, %{outcome: :mismatch}}

      assert {:ok, _} =
               Coordination.release(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-b",
                 force: true
               )

      assert_received {:guard, %{count: 1}, %{outcome: :forced}}
    end

    # A DONE or lease-expired row is nobody's live work. Guarding it answered a dead
    # claim with a 409 telling the caller to retry with force — which cannot clear a
    # terminal state — and made a DONE claim distinguishable from a nonexistent one.
    test "a DONE or EXPIRED claim is decided BEFORE the guard, so it answers as it did" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      peer = [session_id: "session-b"]

      for ref <- ["done", "expired"] do
        assert {:ok, claim} =
                 Coordination.claim(tenant.id, agent, project.id, ref,
                   role: :agent,
                   session_id: "session-a",
                   audit: audit()
                 )

        if ref == "done" do
          assert {:ok, _} =
                   Coordination.done(tenant.id, agent, project.id, ref, audit(),
                     session_id: "session-a"
                   )

          # Terminal: not_found (the deliberate masking) and already_claimed, NOT a 409
          # telling a caller to retry with a force that cannot clear a terminal state.
          assert {:error, :not_found} =
                   Coordination.done(tenant.id, agent, project.id, ref, audit(), peer)

          assert {:error, :already_claimed} =
                   Coordination.release(tenant.id, agent, project.id, ref, audit(), peer)
        else
          # Dead lease: nobody is working it, so any session may free the slot early.
          expire_claim(claim)

          assert {:ok, _} =
                   Coordination.release(tenant.id, agent, project.id, ref, audit(), peer)

          assert is_nil(AdminRepo.get(ChannelClaim, claim.id))
        end
      end
    end

    test "a claim with NO stamped session is UNDISCRIMINABLE and stays agent-scoped" do
      # Pre-#779 rows, curl callers and older MCP servers write no session. Refusing
      # them would lock a live claim out of its own completion for the whole lease.
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:ok, _} =
               Coordination.done(tenant.id, agent, project.id, "r", audit(),
                 session_id: "any-session"
               )
    end

    test "a caller that sends NO session against a STAMPED claim is refused" do
      # Absent counts as different: otherwise any client that simply omits the field
      # walks past the guard, which is the pre-#779 behaviour wearing a new field.
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, :claim_session_mismatch} =
               Coordination.release(tenant.id, agent, project.id, "r", audit())
    end

    # The claim path caps, NUL-checks and denylist-scans `claimed_by_session` because it
    # is client-supplied free text. done/release take the SAME field from the SAME
    # clients, build no claim changeset, and route it into the guard's log line and the
    # APPEND-ONLY audit entry's jsonb metadata — a stricter sink than the `text` column,
    # since Postgres refuses the escape Jason emits for a NUL byte and the request 500s.
    test "#779: a NUL / over-length / credential-shaped session_id on done or release is a 422" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      for bad <- [
            "x" <> <<0>> <> "y",
            String.duplicate("s", ChannelClaim.session_max_length() + 1),
            "sk-ant-api03-" <> String.duplicate("a", 40)
          ],
          call <- [:done, :release] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 apply(Coordination, call, [
                   tenant.id,
                   agent,
                   project.id,
                   "r",
                   audit(),
                   [session_id: bad, force: true]
                 ]),
               "#{call} must refuse #{inspect(binary_part(bad, 0, min(20, byte_size(bad))))}"

        assert %{claimed_by_session: _} = errors_on(cs)
      end

      # Nothing was written: the row is intact, and the audit log carries only the claim.
      row = AdminRepo.get(ChannelClaim, claim.id)
      refute is_nil(row)
      assert is_nil(row.done_at)
      assert claim_audit_actions(tenant.id, claim.id) == ["claimed"]
    end

    test "#779: a credential-shaped session_id on done fires the shared secret_blocked signal" do
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      test_pid = self()
      handler_id = "done-secret-blocked-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :secret_blocked],
        fn _event, measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant.id, do: send(test_pid, {:blocked, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, %Ecto.Changeset{}} =
               Coordination.done(tenant.id, agent, project.id, "r", audit(),
                 session_id: "sk-ant-api03-" <> String.duplicate("a", 40)
               )

      assert_received {:blocked, %{count: 1}, %{field: :claimed_by_session}}
    end

    test "#779: a NON-STRING session_id is refused, not reported as a forced override" do
      # A JSON number or object reached the guard, where `nil != 12345` labelled an
      # UNSTAMPED row `:forced` — a fabricated cross-session override in the very
      # counter an operator alerts on.
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      test_pid = self()
      handler_id = "non-string-session-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :claim_session_guard],
        fn _event, _m, meta, _cfg ->
          if meta[:tenant_id] == tenant.id, do: send(test_pid, {:guard, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:error, %Ecto.Changeset{}} =
               Coordination.done(tenant.id, agent, project.id, "r", audit(),
                 session_id: %{"a" => 1}
               )

      refute_received {:guard, %{outcome: :forced}}
    end

    test "#779: an UNSTAMPED claim is :undiscriminable even when the caller sends no session" do
      # The migration says the residual pre-#779 population — "every claim live at
      # deploy time, every curl caller" — is "made OBSERVABLE instead". A curl caller
      # sends NO session, so keying the outcome on the caller's value made the metric
      # blind to exactly the callers it counts, and an operator read zero as "gone".
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()
      test_pid = self()
      handler_id = "undiscriminable-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :claim_session_guard],
        fn _event, _m, meta, _cfg ->
          if meta[:tenant_id] == tenant.id, do: send(test_pid, {:guard, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent, project.id, "r", role: :agent, audit: audit())

      assert {:ok, _} = Coordination.done(tenant.id, agent, project.id, "r", audit())

      assert_received {:guard, %{outcome: :undiscriminable}}
    end

    test "#779: an EXPIRED-lease release is never recorded as a forced override" do
      # The guard does not run on a dead lease — no telemetry, no warning — so `force`
      # cleared nothing. Recording it as forced puts a false positive in the one signal
      # these audit fields exist to give (KB 07f5e839's incident class).
      %{tenant: tenant, project: project, agent_id: agent} = setup_member()

      assert {:ok, claim} =
               Coordination.claim(tenant.id, agent, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      expire_claim(claim)

      assert {:ok, _} =
               Coordination.release(tenant.id, agent, project.id, "r", audit(),
                 session_id: "session-b",
                 force: true
               )

      assert [_claimed, released] = claim_audit_metadata(tenant.id, claim.id)
      assert released["forced"] == false
      assert released["caller_session"] == "session-b"
    end

    test "a NON-OWNER agent still gets a byte-identical not_found, never the session 409" do
      # The session guard must never become an existence oracle: it runs only AFTER the
      # (tenant, project, claimant_agent_id, ref) owner fetch has already matched.
      %{tenant: tenant, project: project, agent_id: agent_a} = setup_member()
      agent_b = fixture(:agent, %{tenant_id: tenant.id}).id
      make_member(tenant, project, agent_b)

      assert {:ok, _} =
               Coordination.claim(tenant.id, agent_a, project.id, "r",
                 role: :agent,
                 session_id: "session-a",
                 audit: audit()
               )

      assert {:error, :not_found} =
               Coordination.release(tenant.id, agent_b, project.id, "r", audit(),
                 session_id: "session-b"
               )

      assert {:error, :not_found} =
               Coordination.done(tenant.id, agent_b, project.id, "r", audit(),
                 session_id: "session-a"
               )
    end

    test "tenant isolation: the same ref and session in two tenants are independent claims" do
      tenant_a = fixture(:tenant)
      project_a = fixture(:project, %{tenant_id: tenant_a.id})
      agent_a = fixture(:agent, %{tenant_id: tenant_a.id}).id
      make_member(tenant_a, project_a, agent_a)

      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id})
      agent_b = fixture(:agent, %{tenant_id: tenant_b.id}).id
      make_member(tenant_b, project_b, agent_b)

      assert {:ok, a_claim} =
               Coordination.claim(tenant_a.id, agent_a, project_a.id, "handoff:shared#1",
                 role: :agent,
                 session_id: "session-shared",
                 host: "minis",
                 audit: audit()
               )

      assert {:ok, b_claim} =
               Coordination.claim(tenant_b.id, agent_b, project_b.id, "handoff:shared#1",
                 role: :agent,
                 session_id: "session-shared",
                 host: "minis",
                 audit: audit()
               )

      refute a_claim.id == b_claim.id

      # Tenant A's claim is invisible to tenant B's read, session stamp and all.
      {rows, _overflow} = Coordination.claims_page(tenant_b.id, project_b.id, [])
      assert Enum.map(rows, & &1.id) == [b_claim.id]

      # And a matching session id in tenant B cannot end tenant A's claim.
      assert {:error, :not_found} =
               Coordination.release(
                 tenant_b.id,
                 agent_b,
                 project_a.id,
                 "handoff:shared#1",
                 audit(),
                 session_id: "session-shared"
               )

      refute is_nil(AdminRepo.get(ChannelClaim, a_claim.id))
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

    test "#779: a blank session/host normalises to nil, not to a literal empty string" do
      # A session literally named "" would match no live session and lock done/release
      # out behind `force` for the whole lease.
      cs = discriminator_changeset(%{ref: "r", claimed_by_session: "   ", claimed_by_host: ""})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :claimed_by_session) == nil
      assert Ecto.Changeset.get_field(cs, :claimed_by_host) == nil
    end

    test "#779: an over-length or NUL-carrying session/host is a 422, never a 500" do
      long = String.duplicate("s", ChannelClaim.session_max_length() + 1)
      cs = discriminator_changeset(%{ref: "r", claimed_by_session: long})
      refute cs.valid?
      assert %{claimed_by_session: _} = errors_on(cs)

      cs = discriminator_changeset(%{ref: "r", claimed_by_host: "ho\0st"})
      refute cs.valid?
      assert %{claimed_by_host: _} = errors_on(cs)
    end

    test "#779: a credential in the session/host discriminator is refused, not published" do
      # GET /channel/claims echoes both fields to every peer session in the tenant.
      cs =
        discriminator_changeset(%{
          ref: "r",
          claimed_by_session: "sk-ant-api03-" <> String.duplicate("a", 40)
        })

      refute cs.valid?
      assert %{claimed_by_session: _} = errors_on(cs)
    end

    test "a branch-shaped ref is NOT refused by the credential scan" do
      # The denylist's prefixed shapes need only a word boundary, and `-` is not a word
      # character, so scanning `ref` refused ordinary anchors with NO way to clear it:
      # the ref could then never be claimed, and a pre-existing row whose ref tripped
      # the scan lost its idempotent owner re-claim (claim/5 applies this changeset
      # BEFORE the collision is resolved) — the dropped-handoff window that branch
      # exists to close. The residual is accepted, not covered: a claim needs no post,
      # so a credential-shaped ref on a postless claim IS stored unscanned. What
      # `ChannelPost.key`'s scan buys is only that it can never be published together
      # with its instructions.
      cs = discriminator_changeset(%{ref: "handoff:feature/task-sk-integration_with_stripe_v2"})

      assert cs.valid?

      assert SecretDenylist.contains_secret?(
               "handoff:feature/task-sk-integration_with_stripe_v2"
             ),
             "this ref must actually trip the denylist, or the test proves nothing"
    end
  end

  defp discriminator_changeset(attrs) do
    ChannelClaim.create_changeset(
      %ChannelClaim{
        tenant_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        claimant_agent_id: Ecto.UUID.generate(),
        claimed_at: DateTime.utc_now(),
        lease_expires_at: DateTime.utc_now()
      },
      attrs
    )
  end
end
