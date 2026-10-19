defmodule Loopctl.Changes.ReviewCustodyTest do
  @moduledoc """
  US-47.5: review custody for chg-dispatched reviews (Epic 47 PRD §6), at the context:
  `Loopctl.Progress.record_review/4` on a story bound to a chg change (AC-47.5.1..3), the
  chg-root refusal on every terminal custody path and on claim/report (AC-47.5.4), and the
  `:review_missing` escalation a landing takes when no chg review names its revision
  (AC-47.5.5). The HTTP surface, the response bodies and the OpenAPI declarations are
  `LoopctlWeb.ChgReviewCustodyControllerTest`'s; the race on one reviewer dispatch's verdict is
  `Loopctl.Changes.ReviewCustodyLockTest`'s.

  Every lineage here is a `dispatches.lineage_path` the fixture wrote, standing in for what
  `Loopctl.Dispatches.lineage_for_api_key/2` resolves server-side from a key — the context never
  reads it from params.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.AuditChain.Entry
  alias Loopctl.BulkOperations
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.ReviewCustody
  alias Loopctl.Changes.Signature
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Intake
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @repo "mkreyman/infra"

  # ── fixtures ────────────────────────────────────────────────────────────────

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    tenant_id = source.tenant_id

    # The implementer is dispatch-minted under its OWN root — the delivery loop's, never chg's.
    impl_agent = fixture(:agent, %{tenant_id: tenant_id, agent_type: :implementer})

    {:ok, %{dispatch: impl}} =
      Dispatches.create_dispatch(tenant_id, %{role: :agent, agent_id: impl_agent.id})

    epic = fixture(:epic, %{tenant_id: tenant_id})

    story =
      fixture(:story, %{tenant_id: tenant_id, epic_id: epic.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        reported_done_at: DateTime.add(DateTime.utc_now(), -60, :second),
        assigned_agent_id: impl_agent.id,
        implementer_dispatch_id: impl.id
      })
      |> AdminRepo.update!()

    %{
      tenant_id: tenant_id,
      secret: secret,
      source: source,
      root: root,
      impl: impl,
      impl_agent: impl_agent,
      epic: epic,
      story: story
    }
  end

  defp push(ctx, event) do
    raw = Jason.encode!(event)
    ts = Integer.to_string(System.os_time(:second))
    signature = Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
    Events.receive_push(ctx.source.id, %{raw_body: raw, timestamp: ts, signature: signature})
  end

  defp event(change_id, seq, kind, attrs) do
    build(:chg_event, Map.merge(%{change_id: change_id, event_seq: seq, kind: kind}, attrs))
  end

  defp sha(char), do: String.duplicate(char, 40)

  # Binds `story` to `change_id` the way production does: chg reports `submitted` for it.
  defp submit!(ctx, story, change_id, seq, revision, revision_sha) do
    assert {:ok, %{outcome: :applied}} =
             push(
               ctx,
               event(change_id, seq, "submitted", %{
                 revision: revision,
                 sha: revision_sha,
                 data: %{"story_id" => story.id}
               })
             )

    :ok
  end

  defp child(ctx, parent \\ nil),
    do: fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: parent || ctx.root})

  defp reviewer_agent(ctx), do: fixture(:agent, %{tenant_id: ctx.tenant_id})

  defp review(ctx, story, lineage, params, agent_id \\ :fresh) do
    agent_id = if agent_id == :fresh, do: reviewer_agent(ctx).id, else: agent_id

    Progress.record_review(
      ctx.tenant_id,
      story.id,
      Map.merge(%{"review_type" => "chg", "summary" => "chg review"}, params),
      reviewer_agent_id: agent_id,
      reviewer_lineage: lineage
    )
  end

  # An independently-rooted orchestrator dispatch's child: outside chg's subtree.
  defp outsider(ctx) do
    {:ok, %{dispatch: other_root}} =
      Dispatches.create_dispatch(ctx.tenant_id, %{
        role: :orchestrator,
        agent_id: reviewer_agent(ctx).id
      })

    {:ok, %{dispatch: other}} =
      Dispatches.create_dispatch(ctx.tenant_id, %{
        role: :orchestrator,
        agent_id: reviewer_agent(ctx).id,
        parent_dispatch_id: other_root.id
      })

    other
  end

  # ── AC-47.5.1: who may review ───────────────────────────────────────────────

  describe "AC-47.5.1: a chg story takes its review from a strict descendant of the chg root" do
    test "TC-47.5.1: a child of the chg root naming the revision is recorded", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      reviewer = child(ctx)

      assert {:ok, %ReviewRecord{} = record} =
               review(ctx, ctx.story, reviewer.lineage_path, %{"commit_sha" => sha("a")})

      assert record.commit_sha == sha("a")
      assert record.reviewer_dispatch_id == reviewer.id
      assert AdminRepo.get!(ReviewRecord, record.id).commit_sha == sha("a")
    end

    test "a grandchild is a strict descendant too, and records its own dispatch", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      grandchild = child(ctx, child(ctx))

      assert {:ok, record} =
               review(ctx, ctx.story, grandchild.lineage_path, %{"commit_sha" => sha("a")})

      assert record.reviewer_dispatch_id == grandchild.id
    end

    test "chg-server's ROOT key is refused chg_reviewer_required", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, ctx.root.lineage_path, %{"commit_sha" => sha("a")})
    end

    test "TC-47.5.2: an orchestrator outside chg's subtree is refused chg_reviewer_required",
         ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, outsider(ctx).lineage_path, %{"commit_sha" => sha("a")})
    end

    test "a child of ANOTHER registered chg root is refused: the change's own root decides",
         ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      %{root: other_root} =
        fixture(:chg_source, %{tenant_id: ctx.tenant_id, repo_full_name: "mkreyman/other"})

      foreign = fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: other_root})

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, foreign.lineage_path, %{"commit_sha" => sha("a")})
    end

    test "a human operator (nil agent, no lineage) is refused on a chg story", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, [], %{"commit_sha" => sha("a")}, nil)
    end

    test "a bound change whose events no source delivered has no root, so nobody qualifies",
         ctx do
      # A binding written without any event (US-47.1's `bind/4` directly): no source, no root.
      fixture(:change_binding, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, repo: @repo})

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})
    end

    test "one reviewer dispatch records one verdict; a new dispatch records its own", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      reviewer = child(ctx)

      assert {:ok, _} = review(ctx, ctx.story, reviewer.lineage_path, %{"commit_sha" => sha("a")})

      assert {:error, :chg_review_already_recorded} =
               review(ctx, ctx.story, reviewer.lineage_path, %{"commit_sha" => sha("a")})

      assert {:ok, _} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})

      assert AdminRepo.aggregate(
               from(r in ReviewRecord, where: r.reviewer_dispatch_id == ^reviewer.id),
               :count
             ) == 1
    end

    test "the database holds the one-verdict rule, not only the context", ctx do
      reviewer = child(ctx)

      fixture(:review_record, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        commit_sha: sha("a"),
        reviewer_dispatch_id: reviewer.id
      })

      assert_raise Ecto.ConstraintError, ~r/review_records_reviewer_dispatch_uidx/, fn ->
        AdminRepo.insert!(%ReviewRecord{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          review_type: "chg",
          completed_at: DateTime.utc_now(),
          commit_sha: sha("b"),
          reviewer_dispatch_id: reviewer.id
        })
      end
    end

    test "the database refuses a commit_sha without a reviewer dispatch, and the reverse", ctx do
      for {commit_sha, dispatch_id} <- [{sha("a"), nil}, {nil, child(ctx).id}] do
        assert_raise Ecto.ConstraintError, ~r/review_records_chg_review_shape/, fn ->
          AdminRepo.insert!(%ReviewRecord{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            review_type: "chg",
            completed_at: DateTime.utc_now(),
            commit_sha: commit_sha,
            reviewer_dispatch_id: dispatch_id
          })
        end
      end
    end
  end

  # ── AC-47.5.2: which revision ───────────────────────────────────────────────

  describe "AC-47.5.2: commit_sha must be a revision of the story's CURRENT binding" do
    test "absent or malformed is commit_sha_not_bound", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      lineage = child(ctx).lineage_path

      for params <- [
            %{},
            %{"commit_sha" => nil},
            %{"commit_sha" => String.upcase(sha("a"))},
            %{"commit_sha" => "abc123"},
            %{"commit_sha" => 42}
          ] do
        assert {:error, :commit_sha_not_bound} = review(ctx, ctx.story, lineage, params),
               inspect(params)
      end
    end

    test "TC-47.5.3: a revision of a SUPERSEDED binding is not bound; the current one is", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      # The story re-binds to a new change; C1 is superseded.
      :ok = submit!(ctx, ctx.story, "C2", 1, 1, sha("b"))

      assert {:error, :commit_sha_not_bound} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})

      assert {:ok, _} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("b")})
    end

    test "every submitted revision of the current change is bound, not only the newest", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))
      :ok = submit!(ctx, ctx.story, "C1", 2, 2, sha("b"))

      for revision_sha <- [sha("a"), sha("b")] do
        assert {:ok, _} =
                 review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => revision_sha})
      end
    end

    test "the sha of an event that is not a submitted revision is not bound", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:ok, _} =
               push(ctx, event("C1", 2, "check_passed", %{revision: 1, sha: sha("c")}))

      assert {:error, :commit_sha_not_bound} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("c")})
    end

    test "a submitted revision held ahead of a gap is not bound until it applies", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      fixture(:change_event, %{
        tenant_id: ctx.tenant_id,
        source_id: ctx.source.id,
        repo: @repo,
        change_id: "C1",
        event_seq: 5,
        kind: "submitted",
        revision: 3,
        sha: sha("d"),
        applied: false
      })

      assert {:error, :commit_sha_not_bound} =
               review(ctx, ctx.story, child(ctx).lineage_path, %{"commit_sha" => sha("d")})
    end

    test "the reviewer is judged before the sha, so an outsider learns nothing about revisions",
         ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:error, :chg_reviewer_required} =
               review(ctx, ctx.story, outsider(ctx).lineage_path, %{"commit_sha" => "nope"})
    end
  end

  # ── AC-47.5.3: the existing gates, unchanged, first ─────────────────────────

  describe "AC-47.5.3: existing refusals keep their codes; chg checks run in addition" do
    test "a NON-chg story: any separated reviewer is recorded and commit_sha is not stored",
         ctx do
      reviewer = outsider(ctx)

      assert {:ok, first} =
               review(ctx, ctx.story, reviewer.lineage_path, %{"commit_sha" => sha("a")})

      assert first.commit_sha == nil
      assert first.reviewer_dispatch_id == nil

      # No one-verdict rule off the chg path: an orchestrator dispatch reviews many stories,
      # and may record again.
      assert {:ok, _} = review(ctx, ctx.story, reviewer.lineage_path, %{})
      assert ReviewCustody.chg_story(ctx.tenant_id, ctx.story.id) == :not_chg
    end

    test "a NON-chg story: a human operator is still permitted", ctx do
      assert {:ok, _} = review(ctx, ctx.story, [], %{}, nil)
    end

    test "a chg story: a caller on the implementer's chain is self_review_blocked", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      {:ok, %{dispatch: sub}} =
        Dispatches.create_dispatch(ctx.tenant_id, %{
          role: :orchestrator,
          agent_id: reviewer_agent(ctx).id,
          parent_dispatch_id: ctx.impl.id
        })

      assert {:error, :self_review_blocked} =
               review(ctx, ctx.story, sub.lineage_path, %{"commit_sha" => sha("a")})

      # The implementer's own agent id, even from inside chg's tree, is self-review too.
      assert {:error, :self_review_blocked} =
               review(
                 ctx,
                 ctx.story,
                 child(ctx).lineage_path,
                 %{"commit_sha" => sha("a")},
                 ctx.impl_agent.id
               )
    end

    test "a chg story: an unlineaged orchestrator is caller_lineage_required", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      assert {:error, :caller_lineage_required} =
               review(ctx, ctx.story, [], %{"commit_sha" => sha("a")})
    end

    test "a chg story: an unresolvable implementer dispatch is unresolvable_dispatch_lineage",
         ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      # Another tenant's dispatch: the FK is table-wide, the read is tenant-scoped.
      foreign = fixture(:chg_root_dispatch, %{tenant_id: fixture(:tenant).id})

      story =
        ctx.story
        |> Ecto.Changeset.change(implementer_dispatch_id: foreign.id)
        |> AdminRepo.update!()

      assert {:error, :unresolvable_dispatch_lineage} =
               review(ctx, story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})
    end

    test "story_not_reported_done is still the first answer on a chg story", ctx do
      :ok = submit!(ctx, ctx.story, "C1", 1, 1, sha("a"))

      story =
        ctx.story |> Ecto.Changeset.change(agent_status: :implementing) |> AdminRepo.update!()

      assert {:error, :story_not_reported_done} =
               review(ctx, story, outsider(ctx).lineage_path, %{})
    end
  end

  # ── AC-47.5.4: chg-server's keys never certify, implement or report ─────────

  describe "AC-47.5.4: every terminal custody path refuses a chg-rooted caller" do
    # A story ANY separated orchestrator could verify: reviewed, reported, outside chg.
    defp verifiable(ctx) do
      {:ok, _} = review(ctx, ctx.story, outsider(ctx).lineage_path, %{})
      ctx.story
    end

    defp chg_opts(lineage, extra \\ []) do
      [
        orchestrator_agent_id: Ecto.UUID.generate(),
        verifier_lineage: lineage,
        caller_minting_lineage: lineage
      ] ++ extra
    end

    test "TC-47.5.4: verify_story — a chg child and the chg root alike", ctx do
      story = verifiable(ctx)

      for lineage <- [child(ctx).lineage_path, ctx.root.lineage_path] do
        assert {:error, :chg_root_cannot_verify} =
                 Progress.verify_story(ctx.tenant_id, story.id, %{}, chg_opts(lineage))
      end

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified

      # The same story is verifiable by an orchestrator outside chg: the refusal is the caller's.
      other = outsider(ctx)

      assert {:ok, %Story{verified_status: :verified}} =
               Progress.verify_story(ctx.tenant_id, story.id, %{},
                 orchestrator_agent_id: other.agent_id,
                 verifier_lineage: other.lineage_path
               )
    end

    test "reject_story — though reject is exempt from caller_lineage_required", ctx do
      story = verifiable(ctx)

      assert {:error, :chg_root_cannot_verify} =
               Progress.reject_story(
                 ctx.tenant_id,
                 story.id,
                 %{"reason" => "no"},
                 chg_opts(child(ctx).lineage_path)
               )

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
    end

    test "an EXPIRED chg key is still chg's: the minting lineage decides, not the live one",
         ctx do
      story = verifiable(ctx)
      expired = child(ctx)

      # An expired dispatch's key resolves to a LIVE lineage of [] — which reject accepts as an
      # unlineaged caller. Its minting lineage still names chg's root.
      base = [orchestrator_agent_id: reviewer_agent(ctx).id, verifier_lineage: []]

      assert {:error, :chg_root_cannot_verify} =
               Progress.reject_story(
                 ctx.tenant_id,
                 story.id,
                 %{"reason" => "no"},
                 base ++ [caller_minting_lineage: expired.lineage_path]
               )

      assert {:ok, %Story{verified_status: :rejected}} =
               Progress.reject_story(ctx.tenant_id, story.id, %{"reason" => "no"}, base)
    end

    test "verify_all_in_epic refuses the whole epic and verifies nothing", ctx do
      story = verifiable(ctx)

      assert {:error, :chg_root_cannot_verify} =
               Progress.verify_all_in_epic(
                 ctx.tenant_id,
                 ctx.epic.id,
                 %{"summary" => "all"},
                 chg_opts(child(ctx).lineage_path)
               )

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
    end

    test "TC-47.5.4: bulk verify and bulk reject refuse the whole batch", ctx do
      story = verifiable(ctx)
      opts = chg_opts(child(ctx).lineage_path)

      assert {:error, :chg_root_cannot_verify} =
               BulkOperations.bulk_verify(
                 ctx.tenant_id,
                 [%{"story_id" => story.id}],
                 Ecto.UUID.generate(),
                 opts
               )

      assert {:error, :chg_root_cannot_verify} =
               BulkOperations.bulk_reject(
                 ctx.tenant_id,
                 [%{"story_id" => story.id, "reason" => "no"}],
                 Ecto.UUID.generate(),
                 opts
               )

      assert AdminRepo.get!(Story, story.id).verified_status == :unverified
    end

    test "backfill and bulk mark-complete, the paths that verify with no review at all", ctx do
      pending = fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})
      opts = chg_opts(child(ctx).lineage_path)

      assert {:error, :chg_root_cannot_verify} =
               Progress.backfill_story(ctx.tenant_id, pending.id, %{"reason" => "pre"}, opts)

      assert {:error, :chg_root_cannot_verify} =
               BulkOperations.bulk_mark_complete(
                 ctx.tenant_id,
                 [%{"story_id" => pending.id, "summary" => "pre", "review_type" => "pre"}],
                 Ecto.UUID.generate(),
                 opts
               )

      assert AdminRepo.get!(Story, pending.id).verified_status == :unverified
    end

    test "claim, bulk claim and report are chg_root_review_only", ctx do
      contracted =
        fixture(:story, %{tenant_id: ctx.tenant_id, epic_id: ctx.epic.id})
        |> Ecto.Changeset.change(agent_status: :contracted)
        |> AdminRepo.update!()

      agent_child =
        fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id, parent: ctx.root, role: :agent})

      agent = reviewer_agent(ctx)

      assert {:error, :chg_root_review_only} =
               Progress.claim_story(ctx.tenant_id, contracted.id,
                 agent_id: agent.id,
                 lineage: agent_child.lineage_path,
                 caller_minting_lineage: agent_child.lineage_path
               )

      assert {:error, :chg_root_review_only} =
               BulkOperations.bulk_claim(ctx.tenant_id, [contracted.id], agent.id,
                 caller_minting_lineage: agent_child.lineage_path
               )

      assert AdminRepo.get!(Story, contracted.id).agent_status == :contracted

      implementing =
        ctx.story
        |> Ecto.Changeset.change(agent_status: :implementing, reported_done_at: nil)
        |> AdminRepo.update!()

      assert {:error, :chg_root_review_only} =
               Progress.report_story(ctx.tenant_id, implementing.id,
                 agent_id: agent.id,
                 reporter_lineage: child(ctx).lineage_path
               )

      assert AdminRepo.get!(Story, implementing.id).agent_status == :implementing
    end

    test "a revoked source, or one switched back to pr, still marks its root", ctx do
      story = verifiable(ctx)
      lineage = child(ctx).lineage_path

      {:ok, _} = Intake.revoke_source(ctx.tenant_id, ctx.source.id)

      assert {:error, :chg_root_cannot_verify} =
               Progress.verify_story(ctx.tenant_id, story.id, %{}, chg_opts(lineage))

      AdminRepo.update_all(
        from(s in Loopctl.Intake.Source, where: s.id == ^ctx.source.id),
        set: [mode: :pr, revoked_at: nil]
      )

      assert {:error, :chg_root_cannot_verify} =
               Progress.verify_story(ctx.tenant_id, story.id, %{}, chg_opts(lineage))
    end

    test "tenant isolation: another tenant's chg root marks nobody here", ctx do
      %{source: other_source, root: other_root} = fixture(:chg_source, %{})
      refute other_source.tenant_id == ctx.tenant_id

      foreign_lineage =
        fixture(:chg_root_dispatch, %{tenant_id: other_source.tenant_id, parent: other_root}).lineage_path

      assert ReviewCustody.chg_rooted?(other_source.tenant_id, foreign_lineage)
      refute ReviewCustody.chg_rooted?(ctx.tenant_id, foreign_lineage)
      assert :ok = ReviewCustody.refuse_chg_root(ctx.tenant_id, foreign_lineage)
      refute ReviewCustody.chg_rooted?(ctx.tenant_id, [])
    end
  end

  # ── AC-47.5.5: a landing with no review for its revision ────────────────────

  describe "AC-47.5.5: a story that reaches merged with no chg review escalates :review_missing" do
    defp at_ci(ctx, story) do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: story.id, stage: :implementing})
      :ok = submit!(ctx, story, "C1", 1, 1, sha("a"))
      assert {:ok, _} = push(ctx, event("C1", 2, "review_approved", %{data: %{"by" => "policy"}}))
      assert {:ok, _} = push(ctx, event("C1", 3, "check_passed", %{}))
      assert Stages.get(ctx.tenant_id, story.id).stage == :ci
      story
    end

    defp land(ctx, seq, revision, revision_sha) do
      push(
        ctx,
        event("C1", seq, "landed", %{
          revision: revision,
          sha: revision_sha,
          data: %{"merge_sha" => sha("c")}
        })
      )
    end

    defp transitions(ctx, story) do
      for %{from: f, to: t, edge: e} <- Stages.list_transitions(ctx.tenant_id, story.id),
          do: {f, t, e}
    end

    defp landed_effect(ctx, seq) do
      ctx.tenant_id
      |> Events.list_events(@repo, "C1")
      |> Enum.find(&(&1.event_seq == seq))
      |> Map.fetch!(:effect)
      |> Map.fetch!("stage")
    end

    test "TC-47.5.5: an auto-approved landing with no review is merged, then escalated", ctx do
      story = at_ci(ctx, ctx.story)

      assert {:ok, %{outcome: :applied}} = land(ctx, 4, 1, sha("a"))

      row = Stages.get(ctx.tenant_id, story.id)
      assert row.stage == :escalated
      # The merge HELD — trunk has it — so nothing merge-keyed is cleared.
      assert row.merge_sha == sha("c")
      assert row.escalation_reason =~ "review_missing"
      assert row.escalation_reason =~ "revision 1"

      assert Enum.take(transitions(ctx, story), -2) == [
               {"ci", "merged", "forward"},
               {"merged", "escalated", "review_missing"}
             ]

      assert AdminRepo.all(
               from e in Entry,
                 where: e.tenant_id == ^ctx.tenant_id and like(e.action, "story_stage_%"),
                 order_by: [asc: e.chain_position],
                 select: e.action
             ) == ["story_stage_merged", "story_stage_escalated"]

      assert %{
               "outcome" => "moved",
               "to" => "merged",
               "review" => "missing",
               "review_missing" => %{"outcome" => "escalated", "edge" => "review_missing"}
             } = landed_effect(ctx, 4)

      # Never verified: the escalation leaves only over a human's resolution, and a later
      # event moves nothing.
      assert {:ok, _} = push(ctx, event("C1", 5, "deployed", %{data: %{"release" => "v1"}}))
      assert Stages.get(ctx.tenant_id, story.id).stage == :escalated
    end

    test "a chg review recorded for the landed revision lets the merge stand", ctx do
      story = at_ci(ctx, ctx.story)

      assert {:ok, _} = review(ctx, story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})
      assert {:ok, %{outcome: :applied}} = land(ctx, 4, 1, sha("a"))

      assert Stages.get(ctx.tenant_id, story.id).stage == :merged
      assert landed_effect(ctx, 4)["review"] == "recorded"
      refute {"merged", "escalated", "review_missing"} in transitions(ctx, story)
    end

    test "a review of an EARLIER revision does not cover the landed one", ctx do
      story = at_ci(ctx, ctx.story)
      assert {:ok, _} = review(ctx, story, child(ctx).lineage_path, %{"commit_sha" => sha("a")})

      # Revision 2 was pushed and landed; the only review names revision 1.
      assert {:ok, _} =
               push(
                 ctx,
                 event("C1", 4, "submitted", %{
                   revision: 2,
                   sha: sha("b"),
                   data: %{"story_id" => story.id}
                 })
               )

      assert {:ok, _} =
               push(
                 ctx,
                 event("C1", 5, "review_approved", %{revision: 2, data: %{"by" => "policy"}})
               )

      assert {:ok, _} = push(ctx, event("C1", 6, "check_passed", %{revision: 2}))
      assert {:ok, _} = land(ctx, 7, 2, sha("b"))

      assert Stages.get(ctx.tenant_id, story.id).stage == :escalated
    end

    test "a review with no commit_sha (recorded off the chg path) never counts", ctx do
      story = at_ci(ctx, ctx.story)
      fixture(:review_record, %{tenant_id: ctx.tenant_id, story_id: story.id})

      assert {:ok, _} = land(ctx, 4, 1, sha("a"))
      assert Stages.get(ctx.tenant_id, story.id).stage == :escalated
    end

    test "tenant isolation: another tenant's review of the same sha covers nothing here", ctx do
      story = at_ci(ctx, ctx.story)
      other = fixture(:tenant)
      other_story = fixture(:story, %{tenant_id: other.id})

      fixture(:review_record, %{
        tenant_id: other.id,
        story_id: other_story.id,
        commit_sha: sha("a"),
        reviewer_dispatch_id: fixture(:chg_root_dispatch, %{tenant_id: other.id}).id
      })

      assert {:ok, _} = land(ctx, 4, 1, sha("a"))
      assert Stages.get(ctx.tenant_id, story.id).stage == :escalated
      refute ReviewCustody.reviewed_revision?(AdminRepo, ctx.tenant_id, other_story.id, sha("a"))
    end
  end
end
