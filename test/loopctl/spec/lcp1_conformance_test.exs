defmodule Loopctl.Spec.LCP1ConformanceTest do
  @moduledoc """
  Executable conformance suite for `docs/spec/LCP-1-custody-claims.md`.

  This file exists to check the SPEC against the CODE, in that direction. Every
  test cites the clause it exercises and is constructed so that exactly ONE
  clause matches — a test that passes because a different clause fired first
  would be worthless as a conformance check, so the construction is part of the
  assertion.

  The two LCP-1 §7.5 clause-three cases (a declared-but-unresolvable implementer
  dispatch must reject at `report` and `review_complete`, not fall through to
  agent-id equality) were the one place the spec and the code diverged. They were
  briefly tagged `:lcp1_gap` while the fix landed; the fix is in
  `lineage_status/2` (progress.ex), so the tests now run in the default suite. They
  are named `§7.5 clause 3 …` below.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches
  alias Loopctl.Progress

  # ── §5.2 SHARES_ROOT ──────────────────────────────────────────────────────
  #
  # The predicate is a shared-ROOT test, not a longest-common-prefix test. The
  # sibling case is what distinguishes the two and is the reason this table is
  # exhaustive rather than illustrative.

  @root "11111111-1111-1111-1111-111111111111"
  @other "22222222-2222-2222-2222-222222222222"
  @child_a "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @child_b "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

  @shares_root_vectors [
    {"empty vs empty", [], [], false},
    {"empty vs non-empty", [], [@root], false},
    {"non-empty vs empty", [@root], [], false},
    {"same single root", [@root], [@root], true},
    {"different single root", [@root], [@other], false},
    {"siblings under one root", [@root, @child_a], [@root, @child_b], true},
    {"same root, different depth", [@root], [@root, @child_a], true},
    {"different roots, equal depth", [@root, @child_a], [@other, @child_a], false},
    {"root of one equals child of other", [@child_a], [@root, @child_a], false}
  ]

  describe "LCP-1 §5.2 SHARES_ROOT" do
    for {label, a, b, expected} <- @shares_root_vectors do
      test "#{label} → #{expected}" do
        assert Dispatches.lineage_shares_prefix?(unquote(a), unquote(b)) == unquote(expected)
      end
    end

    test "siblings share a root — this is what makes it NOT a common-prefix test" do
      # A longest-common-prefix implementation would compare [root, a] to
      # [root, b], find the prefixes diverge at index 1, and report "separated".
      # That would let two agents dispatched by the same parent verify each
      # other's work, which is the exact failure the predicate exists to prevent.
      assert Dispatches.lineage_shares_prefix?([@root, @child_a], [@root, @child_b])
    end

    test "the last vector pins asymmetry: a shared ELEMENT is not a shared ROOT" do
      refute Dispatches.lineage_shares_prefix?([@child_a], [@root, @child_a])
    end
  end

  # ── Gate fixtures ─────────────────────────────────────────────────────────

  defp tenant_with_story(story_attrs \\ %{}) do
    tenant = fixture(:tenant)
    epic = fixture(:epic, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
      |> Ecto.Changeset.change(story_attrs)
      |> AdminRepo.update!()

    %{tenant: tenant, epic: epic, agent: agent, story: story}
  end

  defp implementing_story(attrs \\ %{}) do
    ctx = tenant_with_story()

    story =
      ctx.story
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            agent_status: :implementing,
            assigned_agent_id: ctx.agent.id,
            assigned_at: DateTime.utc_now()
          },
          attrs
        )
      )
      |> AdminRepo.update!()

    %{ctx | story: story}
  end

  defp reported_story(attrs \\ %{}) do
    ctx = tenant_with_story()

    story =
      ctx.story
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            agent_status: :reported_done,
            assigned_agent_id: ctx.agent.id,
            assigned_at: DateTime.utc_now(),
            reported_done_at: DateTime.utc_now()
          },
          attrs
        )
      )
      |> AdminRepo.update!()

    %{ctx | story: story}
  end

  defp a_dispatch(tenant_id, agent_id, role \\ :agent) do
    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant_id, %{role: role, agent_id: agent_id})

    dispatch
  end

  # ── §7.2 report ───────────────────────────────────────────────────────────

  describe "LCP-1 §7.2 report" do
    test "clause 1 — nil caller identity is REJECTED, never permissive" do
      ctx = implementing_story()

      assert {:error, :self_report_blocked} =
               Progress.report_story(ctx.tenant.id, ctx.story.id, agent_id: nil)
    end

    test "clause 2 — UNATTRIBUTED story rejects with :missing_assigned_agent" do
      # No assigned agent AND no implementer dispatch: every identity comparison
      # below would pass vacuously, so the gate must reject before reaching them.
      ctx = implementing_story(%{assigned_agent_id: nil, implementer_dispatch_id: nil})
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :implementer})

      assert {:error, :missing_assigned_agent} =
               Progress.report_story(ctx.tenant.id, ctx.story.id, agent_id: other.id)
    end

    test "clause 3 — reporter sharing the implementer's lineage root is REJECTED" do
      ctx = implementing_story()
      impl_dispatch = a_dispatch(ctx.tenant.id, ctx.agent.id)

      story =
        ctx.story
        |> Ecto.Changeset.change(%{implementer_dispatch_id: impl_dispatch.id})
        |> AdminRepo.update!()

      # A DIFFERENT agent id, so clause 4 cannot be what fires — the rejection
      # must come from the lineage comparison alone.
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :implementer})
      shared_root = List.first(impl_dispatch.lineage_path)

      assert {:error, :self_report_blocked} =
               Progress.report_story(ctx.tenant.id, story.id,
                 agent_id: other.id,
                 reporter_lineage: [shared_root, Ecto.UUID.generate()]
               )
    end

    test "clause 4 — reporter equal to the assigned agent is REJECTED" do
      ctx = implementing_story()

      assert {:error, :self_report_blocked} =
               Progress.report_story(ctx.tenant.id, ctx.story.id, agent_id: ctx.agent.id)
    end

    test "clause 5 — an independent reporter is PERMITTED" do
      ctx = implementing_story()
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:ok, story} =
               Progress.report_story(ctx.tenant.id, ctx.story.id, agent_id: other.id)

      assert story.agent_status == :reported_done
    end

    test "§7.5 clause 3 — a DECLARED but unresolvable implementer dispatch must REJECT" do
      # LCP-1 §7.5: a recorded dispatch id that cannot be resolved is an
      # INTEGRITY FAILURE, not an absence of delegation. It fails CLOSED under its
      # own error code (:unresolvable_dispatch_lineage) rather than being mislabeled
      # a self-report, so the caller sees the real cause and the tenant is NOT halted.
      ctx = implementing_story(%{implementer_dispatch_id: foreign_dispatch_id()})
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :implementer})

      assert {:error, :unresolvable_dispatch_lineage} =
               Progress.report_story(ctx.tenant.id, ctx.story.id,
                 agent_id: other.id,
                 reporter_lineage: [Ecto.UUID.generate()]
               )
    end
  end

  # ── §7.3 review_complete ──────────────────────────────────────────────────

  describe "LCP-1 §7.3 review_complete" do
    test "clause 1 — ORPHANED story rejects with :missing_assigned_agent" do
      ctx = reported_story(%{assigned_agent_id: nil, implementer_dispatch_id: nil})
      reviewer = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :missing_assigned_agent} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: reviewer.id
               )
    end

    test "clause 2 — nil reviewer is PERMITTED (human operator)" do
      # The documented departure from "nil is never permissive". Sound only
      # because the transport gate admits no agent-role key here and the handler
      # rejects an orchestrator key carrying no agent id; see §7.3 (a)/(b).
      ctx = reported_story()

      assert {:ok, _review} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: nil
               )
    end

    test "clause 1 precedes clause 2 — an ORPHANED story rejects even a nil reviewer" do
      # Ordering is normative: if clause 2 were evaluated first, a human operator
      # could review a story with no known implementer.
      ctx = reported_story(%{assigned_agent_id: nil, implementer_dispatch_id: nil})

      assert {:error, :missing_assigned_agent} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: nil
               )
    end

    test "clause 3 — reviewer sharing the implementer's lineage root is REJECTED" do
      ctx = reported_story()
      impl_dispatch = a_dispatch(ctx.tenant.id, ctx.agent.id)

      story =
        ctx.story
        |> Ecto.Changeset.change(%{implementer_dispatch_id: impl_dispatch.id})
        |> AdminRepo.update!()

      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})
      shared_root = List.first(impl_dispatch.lineage_path)

      assert {:error, :self_review_blocked} =
               Progress.record_review(ctx.tenant.id, story.id, review_params(),
                 reviewer_agent_id: other.id,
                 reviewer_lineage: [shared_root, Ecto.UUID.generate()]
               )
    end

    test "clause 4 — reviewer equal to the assigned agent is REJECTED" do
      ctx = reported_story()

      assert {:error, :self_review_blocked} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: ctx.agent.id
               )
    end

    test "clause 5 — an independent reviewer is PERMITTED" do
      ctx = reported_story()
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:ok, _review} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: other.id
               )
    end

    test "§7.5 clause 3 — a DECLARED but unresolvable implementer dispatch must REJECT" do
      ctx = reported_story(%{implementer_dispatch_id: foreign_dispatch_id()})
      other = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :unresolvable_dispatch_lineage} =
               Progress.record_review(ctx.tenant.id, ctx.story.id, review_params(),
                 reviewer_agent_id: other.id,
                 reviewer_lineage: [Ecto.UUID.generate()]
               )
    end
  end

  # ── §7.4 verify ───────────────────────────────────────────────────────────

  describe "LCP-1 §7.4 verify" do
    test "clause 1 — nil caller identity is REJECTED" do
      ctx = reported_story()
      assert {:error, :self_verify_blocked} = Progress.ensure_verify_allowed(ctx.story, nil)
    end

    test "clause 2 — ORPHANED story rejects with :missing_assigned_agent" do
      ctx = reported_story(%{assigned_agent_id: nil, implementer_dispatch_id: nil})
      verifier = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :missing_assigned_agent} =
               Progress.ensure_verify_allowed(ctx.story, verifier.id)
    end

    test "clause 4 — verifier equal to the assigned agent is REJECTED (no dispatches)" do
      ctx = reported_story()

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(ctx.story, ctx.agent.id)
    end

    test "clause 5 — an independent verifier is PERMITTED (no dispatches)" do
      ctx = reported_story()
      verifier = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})
      assert :ok = Progress.ensure_verify_allowed(ctx.story, verifier.id)
    end

    test "§7.4.1 clause 1 — an unresolvable dispatch FAILS CLOSED" do
      # Both ids declared, neither resolvable. SHARES_ROOT([], []) is false, so a
      # naive implementation would read this as separated lineage and PERMIT.
      ctx =
        reported_story(%{
          implementer_dispatch_id: foreign_dispatch_id(),
          verifier_dispatch_id: foreign_dispatch_id()
        })

      verifier = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      assert {:error, :unresolvable_dispatch_lineage} =
               Progress.ensure_verify_allowed(ctx.story, verifier.id)
    end

    test "§7.4.1 clause 2 — shared lineage root is REJECTED" do
      ctx = reported_story()
      impl = a_dispatch(ctx.tenant.id, ctx.agent.id)
      verifier_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})

      {:ok, %{dispatch: child}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :orchestrator,
          agent_id: verifier_agent.id,
          parent_dispatch_id: impl.id
        })

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          implementer_dispatch_id: impl.id,
          verifier_dispatch_id: child.id
        })
        |> AdminRepo.update!()

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, verifier_agent.id)
    end

    test "§7.4.1 clause 3 — separated lineage does NOT short-circuit the agent-id check" do
      # The clause that a short-circuiting implementation skips: lineages are
      # genuinely separated, but the caller IS the assigned agent. Permitting
      # here would let an implementer verify its own work through a second,
      # independently-rooted dispatch.
      ctx = reported_story()
      impl = a_dispatch(ctx.tenant.id, ctx.agent.id)
      verifier_dispatch = a_dispatch(ctx.tenant.id, ctx.agent.id, :orchestrator)

      refute Dispatches.lineage_shares_prefix?(
               impl.lineage_path,
               verifier_dispatch.lineage_path
             )

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          implementer_dispatch_id: impl.id,
          verifier_dispatch_id: verifier_dispatch.id
        })
        |> AdminRepo.update!()

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, ctx.agent.id)
    end

    test "§7.4.1 clause 4 — separated lineage and a distinct verifier is PERMITTED" do
      ctx = reported_story()
      impl = a_dispatch(ctx.tenant.id, ctx.agent.id)
      verifier_agent = fixture(:agent, %{tenant_id: ctx.tenant.id, agent_type: :orchestrator})
      verifier_dispatch = a_dispatch(ctx.tenant.id, verifier_agent.id, :orchestrator)

      story =
        ctx.story
        |> Ecto.Changeset.change(%{
          implementer_dispatch_id: impl.id,
          verifier_dispatch_id: verifier_dispatch.id
        })
        |> AdminRepo.update!()

      assert :ok = Progress.ensure_verify_allowed(story, verifier_agent.id)
    end
  end

  defp review_params do
    %{
      review_type: "lcp1-conformance",
      findings: "conformance vector",
      completed_at: DateTime.utc_now()
    }
  end

  # LCP-1 §7.5 row two: a dispatch id that is DECLARED and does not resolve.
  #
  # The FK on `stories.implementer_dispatch_id` is table-wide while
  # `Dispatches.get_dispatch/2` scopes by `(id, tenant_id)`, so this state is
  # reachable exactly one way: an id belonging to ANOTHER tenant. A random UUID
  # cannot express it — the FK rejects the write. That makes the §7.5 gap a
  # cross-tenant isolation case rather than a deleted-row edge case, which is
  # why these vectors mint a foreign dispatch instead of fabricating an id.
  defp foreign_dispatch_id do
    other_tenant = fixture(:tenant)
    other_agent = fixture(:agent, %{tenant_id: other_tenant.id, agent_type: :implementer})
    a_dispatch(other_tenant.id, other_agent.id).id
  end
end
