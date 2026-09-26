defmodule Loopctl.Threads.ReviewsTest do
  @moduledoc """
  US-45.3: review dispatches, checkpoint-bound findings, fixes and the round ceiling.

  `async: false`, and COMMITTED rather than sandboxed, for the reason
  `Loopctl.Delivery.PlacementTest` gives: review placement spans both repos — the story and the
  thread live on the RLS `Repo`, while dispatches and their keys are written on `AdminRepo` —
  and the two sandbox connections cannot see each other's uncommitted rows. Worse, both append
  to the tenant's audit chain, so a sandboxed thread write holds the chain lock that the mint
  then waits on for ever. So every test body runs on real connections (`committed_test/3`),
  and `sweep_committed_runner_tenants/0` removes what it wrote.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Dispatches
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Reviews
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @tree String.duplicate("c", 40)

  # BOTH repos on real connections, as every call in `Loopctl.Delivery.PlacementTest` is.
  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Repo, fun) end)
  end

  setup do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    ctx = fixture(:review_story, %{tenant_id: tenant.id, claim_epoch: 2})
    {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    {:ok, Map.put(ctx, :operator, operator)}
  end

  # --- helpers ---------------------------------------------------------------------------

  defp sha(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")

  defp checkpoint(ctx, n, overrides \\ []) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(
        ctx.tenant_id,
        ctx.story.id,
        Keyword.merge(
          [
            agent_id: ctx.implementer.id,
            claim_epoch: current_epoch(ctx),
            commit_sha: sha(n),
            tree_sha: @tree,
            author_principal: "agent:#{ctx.implementer.id}",
            actor_lineage: ctx.session.lineage_path
          ],
          overrides
        )
      )

    cp
  end

  defp current_epoch(ctx) do
    {:ok, epoch} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^ctx.story.id, select: s.claim_epoch)
      end)

    epoch
  end

  defp set_story(ctx, fields) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in Story, where: s.id == ^ctx.story.id) |> Repo.update_all(set: fields)
      end)
  end

  defp place(ctx, opts \\ []) do
    Reviews.place(
      ctx.tenant_id,
      ctx.story.id,
      Keyword.get(opts, :caller, ctx.orch_key),
      Keyword.merge([agent_id: ctx.reviewer.id], Keyword.delete(opts, :caller))
    )
  end

  defp placed!(ctx, opts \\ []) do
    {:ok, %{review: review, raw_key: raw}} = place(ctx, opts)
    %{review: review, raw: raw, key: key_of(raw)}
  end

  defp key_of(raw) do
    {:ok, key} = Loopctl.Auth.verify_api_key(raw)
    key
  end

  defp finding(ctx, key, attrs) do
    Reviews.record_finding(
      ctx.tenant_id,
      ctx.story.id,
      key,
      Map.merge(
        %{
          "idempotency_key" => "f-#{System.unique_integer([:positive])}",
          "body" => "the lock is taken after the chain",
          "severity" => "high"
        },
        attrs
      )
    )
  end

  defp finding!(ctx, key, attrs) do
    {:ok, entry, :created} = finding(ctx, key, attrs)
    entry
  end

  defp verdict(ctx, key, idem \\ nil) do
    Reviews.record_verdict(ctx.tenant_id, ctx.story.id, key, %{
      "idempotency_key" => idem || "v-#{System.unique_integer([:positive])}",
      "body" => "round done"
    })
  end

  defp verdict!(ctx, key, idem \\ nil) do
    {:ok, written, :created} = verdict(ctx, key, idem)
    written
  end

  defp fix(ctx, checkpoint, finding_ids, attrs \\ %{}) do
    Reviews.record_fix(
      ctx.tenant_id,
      ctx.story.id,
      ctx.impl_key,
      Map.merge(
        %{
          "claim_epoch" => current_epoch(ctx),
          "checkpoint_id" => checkpoint.id,
          "finding_ids" => finding_ids,
          "idempotency_key" => "x-#{System.unique_integer([:positive])}",
          "body" => "moved the lock"
        },
        attrs
      )
    )
  end

  defp code({:error, {_status, code, _message}}), do: code
  defp code(other), do: other

  # A full round 1 on checkpoint 1 with one finding, and its fix on checkpoint 2.
  defp round_one_fixed(ctx, severity \\ "high") do
    cp1 = checkpoint(ctx, 1)
    r1 = placed!(ctx)
    f1 = finding!(ctx, r1.key, %{"severity" => severity})
    verdict!(ctx, r1.key)
    cp2 = checkpoint(ctx, 2)
    {:ok, fix, :created} = fix(ctx, cp2, [f1.id])
    %{cp1: cp1, cp2: cp2, r1: r1, f1: f1, fix: fix}
  end

  # --- AC-45.3.1: placement ---------------------------------------------------------------

  describe "place/4" do
    test "mints a SIBLING of the implementer's dispatch for round 1 on the latest checkpoint",
         ctx do
      unboxed(fn ->
        _cp1 = checkpoint(ctx, 1)
        cp2 = checkpoint(ctx, 2)

        %{review: review, raw: raw} = placed!(ctx)

        assert review.round == 1
        assert review.checkpoint_id == cp2.id
        assert review.agent_id == ctx.reviewer.id
        assert is_binary(raw)

        {:ok, dispatch} = Dispatches.get_dispatch(ctx.tenant_id, review.dispatch_id)
        assert dispatch.parent_dispatch_id == ctx.session.parent_dispatch_id
        assert dispatch.lineage_path == [ctx.root.id, dispatch.id]
        refute Dispatches.lineage_same_chain?(dispatch.lineage_path, ctx.session.lineage_path)
        assert dispatch.agent_id == ctx.reviewer.id

        {:ok, actions} =
          Repo.with_tenant(ctx.tenant_id, fn ->
            Repo.all(
              from c in ChainEntry,
                where: c.tenant_id == ^ctx.tenant_id and c.entity_id == ^ctx.story.id,
                select: c.action
            )
          end)

        assert "thread_review_placed" in actions
      end)
    end

    test "an explicit checkpoint must be one of this story's", ctx do
      unboxed(fn ->
        cp1 = checkpoint(ctx, 1)
        _cp2 = checkpoint(ctx, 2)

        assert {:ok, %{review: %{checkpoint_id: id}}} = place(ctx, checkpoint_id: cp1.id)
        assert id == cp1.id

        assert "unknown_checkpoint" == code(place(ctx, checkpoint_id: Ecto.UUID.generate()))
        assert "invalid_expires_in_seconds" == code(place(ctx, expires_in_seconds: "soon"))
      end)
    end

    test "never for the claimant, nor for a principal that recorded a checkpoint",
         ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)

        assert "reviewer_not_separate" == code(place(ctx, agent_id: ctx.implementer.id))

        # The spare agent's principal recorded a checkpoint of this thread.
        checkpoint(ctx, 2, author_principal: "agent:#{ctx.spare.id}")
        assert "reviewer_not_separate" == code(place(ctx, agent_id: ctx.spare.id))

        assert {:ok, _} = place(ctx, agent_id: ctx.reviewer.id)
      end)
    end

    test "never by a caller on the implementer's chain, nor outside its parent", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)

        below =
          mint!(ctx.tenant_id, %{
            parent_dispatch_id: ctx.session.id,
            role: :orchestrator,
            agent_id: ctx.spare.id
          })

        assert "review_placer_on_implementer_chain" == code(place(ctx, caller: below))

        elsewhere = mint!(ctx.tenant_id, %{role: :orchestrator, agent_id: ctx.reviewer.id})
        assert "parent_outside_caller_lineage" == code(place(ctx, caller: elsewhere))
      end)
    end

    test "an agent-role key may not place one", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        assert "insufficient_role" == code(place(ctx, caller: ctx.impl_key))
      end)
    end

    test "the tenant's operator key may place one", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        operator = ctx.operator
        assert {:ok, %{review: %{round: 1}}} = place(ctx, caller: operator)
      end)
    end

    test "a claim no dispatch made, and a thread with no checkpoint, are refused",
         ctx do
      unboxed(fn ->
        assert "no_checkpoint" == code(place(ctx))

        checkpoint(ctx, 1)
        set_story(ctx, implementer_dispatch_id: nil)
        assert "implementer_dispatch_required" == code(place(ctx))
      end)
    end

    test "an implementer parent that is revoked cannot parent the review", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)

        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

        operator = ctx.operator
        assert "review_parent_inactive" == code(place(ctx, caller: operator))
      end)
    end

    test "a halted tenant places nothing", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)

        AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
          set: [custody_halted_at: DateTime.utc_now()]
        )

        assert {:error, :tenant_halted} = place(ctx)
      end)
    end

    test "tenant isolation: another tenant's key and another tenant's story", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
        other_ctx = fixture(:review_story, %{tenant_id: other.id})

        assert {:error, :not_authorized} = place(ctx, caller: other_ctx.orch_key)

        assert {:error, :not_found} =
                 Reviews.place(ctx.tenant_id, other_ctx.story.id, ctx.orch_key,
                   agent_id: ctx.reviewer.id
                 )

        # Another tenant's agent is not an agent of this tenant.
        assert "unknown_agent" == code(place(ctx, agent_id: other_ctx.reviewer.id))
      end)
    end

    test "a ROOT implementer's sibling is a root, which only the operator may mint", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        root_impl = mint!(ctx.tenant_id, %{role: :agent, agent_id: ctx.spare.id})
        {:ok, root_dispatch} = Dispatches.dispatch_for_api_key(ctx.tenant_id, root_impl.id)
        set_story(ctx, implementer_dispatch_id: root_dispatch.id)

        assert "root_dispatch_forbidden" == code(place(ctx))

        assert {:ok, %{review: review}} = place(ctx, caller: ctx.operator)
        {:ok, dispatch} = Dispatches.get_dispatch(ctx.tenant_id, review.dispatch_id)
        assert dispatch.lineage_path == [dispatch.id]
      end)
    end
  end

  # --- AC-45.3.3 / AC-45.3.4: findings --------------------------------------------------

  describe "record_finding/4" do
    test "only a placed review dispatch judges (TC-45.3.1)", ctx do
      unboxed(fn ->
        cp = checkpoint(ctx, 1)
        %{review: review, key: key} = placed!(ctx)
        operator = ctx.operator

        assert "review_dispatch_required" == code(finding(ctx, ctx.impl_key, %{}))

        # A released implementer still holds the key its dispatch minted.
        set_story(ctx, assigned_agent_id: nil, agent_status: :pending, claim_epoch: 3)
        assert "review_dispatch_required" == code(finding(ctx, ctx.impl_key, %{}))

        assert "review_dispatch_required" == code(finding(ctx, operator, %{}))

        assert {:ok, entry, :created} = finding(ctx, key, %{"location" => "lib/a.ex:10"})
        assert entry.kind == :finding
        assert entry.review_id == review.id
        assert entry.checkpoint_id == cp.id
        assert entry.severity == :high
        assert entry.location == "lib/a.ex:10"
        assert entry.dispatch_id == review.dispatch_id
        assert entry.author_principal == "agent:#{ctx.reviewer.id}"

        # The chain pins what the rounds are computed from.
        {:ok, payload} =
          Repo.with_tenant(ctx.tenant_id, fn ->
            Repo.one(
              from c in ChainEntry,
                where: c.tenant_id == ^ctx.tenant_id and c.action == "thread_finding_recorded",
                select: c.payload
            )
          end)

        assert payload["review_id"] == review.id
        assert payload["severity"] == "high"
      end)
    end

    test "a review dispatch of ANOTHER story is not this story's reviewer", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)

        other = fixture(:committed_story, %{tenant_id: ctx.tenant_id})

        assert "review_dispatch_required" ==
                 code(
                   Reviews.record_finding(ctx.tenant_id, other.id, key, %{
                     "idempotency_key" => "k",
                     "body" => "b",
                     "severity" => "low"
                   })
                 )
      end)
    end

    test "severity is one of four, canonicalised", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)

        assert "invalid_severity" == code(finding(ctx, key, %{"severity" => "urgent"}))

        assert {:ok, %{severity: :critical}, :created} =
                 finding(ctx, key, %{"severity" => "CRITICAL"})
      end)
    end

    test "introduced_by is refused in round 1", ctx do
      unboxed(fn ->
        cp = checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)

        assert "introduced_by_not_allowed" == code(finding(ctx, key, %{"introduced_by" => cp.id}))
      end)
    end

    test "after round 1 introduced_by is required, canonical, and not after the checkpoint (TC-45.3.4)",
         ctx do
      unboxed(fn ->
        %{cp1: cp1, cp2: cp2} = round_one_fixed(ctx)
        %{key: key} = placed!(ctx, checkpoint_id: cp2.id)

        assert "introduced_by_required" == code(finding(ctx, key, %{}))
        assert "introduced_by_invalid" == code(finding(ctx, key, %{"introduced_by" => "nope"}))

        # A checkpoint recorded AFTER the one the finding was found in.
        cp3 = checkpoint(ctx, 3)
        assert "introduced_by_invalid" == code(finding(ctx, key, %{"introduced_by" => cp3.id}))

        assert {:ok, %{introduced_by: "none"}, :created} =
                 finding(ctx, key, %{"introduced_by" => " NONE "})

        assert {:ok, %{introduced_by: canonical}, :created} =
                 finding(ctx, key, %{"introduced_by" => String.upcase(cp1.id)})

        assert canonical == cp1.id
      end)
    end

    test "a resend is answered from its row", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)
        attrs = %{"idempotency_key" => "same", "severity" => "low"}

        {:ok, first, :created} = finding(ctx, key, attrs)
        assert {:ok, ^first, :existing} = finding(ctx, key, attrs)

        assert "idempotency_key_reused" ==
                 code(finding(ctx, key, Map.put(attrs, "severity", "high")))
      end)
    end

    test "the reviewer's agent becoming the claimant stops its judgements", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)

        set_story(ctx, assigned_agent_id: ctx.reviewer.id)
        assert "reviewer_not_separate" == code(finding(ctx, key, %{}))
      end)
    end
  end

  # --- AC-45.3.3: verdicts, and what a round is ----------------------------------------

  describe "record_verdict/4" do
    test "one verdict per dispatch, which closes it; nothing after it (TC-45.3.3)", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key, review: review} = placed!(ctx)

        assert {:ok, %{entry: verdict, escalation: nil}, :created} = verdict(ctx, key, "v1")
        assert verdict.kind == :verdict

        # The verdict revokes the review dispatch, and with it the key.
        assert :none == Dispatches.dispatch_for_api_key(ctx.tenant_id, key.id)
        assert "review_dispatch_required" == code(verdict(ctx, key, "v2"))

        # Were the revocation to fail, the review is closed all the same, and a resend of
        # its verdict is still answered from the row.
        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^review.dispatch_id),
          set: [revoked_at: nil]
        )

        assert {:ok, %{entry: ^verdict}, :existing} = verdict(ctx, key, "v1")
        assert "review_closed" == code(verdict(ctx, key, "v2"))
        assert "review_closed" == code(finding(ctx, key, %{}))

        assert %{completed: 1, next_round: 2} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      end)
    end

    test "a dispatch that ends without a verdict uses no round", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key, review: review} = placed!(ctx)
        finding!(ctx, key, %{})

        {:ok, _} = Dispatches.revoke(ctx.tenant_id, review.dispatch_id)
        assert %{completed: 0, next_round: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)

        assert {:ok, %{review: %{round: 1}}} = place(ctx)
      end)
    end

    test "a verdict key reused by the same agent in a later round is not that round's replay",
         ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: r1} = placed!(ctx)
        verdict!(ctx, r1, "same-key")
        %{key: r2} = placed!(ctx)

        assert "idempotency_key_reused" == code(verdict(ctx, r2, "same-key"))
        assert %{completed: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      end)
    end

    test "the database holds a review to one verdict", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: key, review: review} = placed!(ctx)
        %{entry: verdict} = verdict!(ctx, key)

        second =
          %{
            kind: :verdict,
            idempotency_key: "raw",
            body: "again",
            checkpoint_id: review.checkpoint_id
          }
          |> Entry.system_changeset()
          |> Ecto.Changeset.change(
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            seq: verdict.seq + 10,
            author_principal: "agent:#{ctx.reviewer.id}",
            review_id: review.id
          )

        assert_raise Ecto.ConstraintError, ~r/thread_entries_one_verdict_per_review_uidx/, fn ->
          Repo.with_tenant(ctx.tenant_id, fn -> Repo.insert(second) end)
        end
      end)
    end

    test "two reviews placed for one round cannot both complete it", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{key: first} = placed!(ctx)
        %{key: second} = placed!(ctx, agent_id: ctx.spare.id)
        assert "reviewer_agent_busy" == code(place(ctx))

        verdict!(ctx, first)
        assert "review_round_superseded" == code(verdict(ctx, second))
        assert "review_round_superseded" == code(finding(ctx, second, %{}))
        assert %{completed: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      end)
    end
  end

  # --- AC-45.3.5: fixes ------------------------------------------------------------------

  describe "record_fix/4" do
    setup ctx do
      unboxed(fn ->
        cp1 = checkpoint(ctx, 1)
        %{key: key} = placed!(ctx)
        f1 = finding!(ctx, key, %{})
        verdict!(ctx, key)
        {:ok, cp1: cp1, f1: f1}
      end)
    end

    test "the claimant names a finding, on a later checkpoint of its claim", ctx do
      unboxed(fn ->
        cp2 = checkpoint(ctx, 2)

        assert {:ok, entry, :created} = fix(ctx, cp2, [String.upcase(ctx.f1.id)])
        assert entry.kind == :fix
        assert entry.checkpoint_id == cp2.id
        assert entry.finding_ids == [ctx.f1.id]
      end)
    end

    test "a fix on the checkpoint its finding was found in, or an older one, is refused",
         ctx do
      unboxed(fn ->
        assert "fix_checkpoint_not_after_findings" == code(fix(ctx, ctx.cp1, [ctx.f1.id]))
      end)
    end

    test "a fix under an ended claim is refused (TC-45.3.4)", ctx do
      unboxed(fn ->
        cp2 = checkpoint(ctx, 2)
        epoch = current_epoch(ctx)

        set_story(ctx, claim_epoch: epoch + 1)

        assert {:error, :stale_claim_epoch} =
                 fix(ctx, cp2, [ctx.f1.id], %{"claim_epoch" => epoch})

        # The new claim's epoch, citing a checkpoint the ENDED claim recorded.
        assert "fix_checkpoint_not_current_claim" ==
                 code(fix(ctx, cp2, [ctx.f1.id], %{"claim_epoch" => epoch + 1}))
      end)
    end

    test "another agent, and a lapsed lease, are refused", ctx do
      unboxed(fn ->
        cp2 = checkpoint(ctx, 2)

        assert {:error, :not_claimant} =
                 Reviews.record_fix(ctx.tenant_id, ctx.story.id, ctx.orch_key, %{
                   "claim_epoch" => current_epoch(ctx),
                   "checkpoint_id" => cp2.id,
                   "finding_ids" => [ctx.f1.id],
                   "idempotency_key" => "o",
                   "body" => "b"
                 })

        set_story(ctx, claimed_until: DateTime.add(DateTime.utc_now(), -60))
        assert {:error, :claim_not_live} = fix(ctx, cp2, [ctx.f1.id])
      end)
    end

    test "finding_ids must name findings of this story's completed rounds", ctx do
      unboxed(fn ->
        cp2 = checkpoint(ctx, 2)

        assert "finding_ids_required" == code(fix(ctx, cp2, []))
        assert "finding_ids_required" == code(fix(ctx, cp2, ["nope"]))
        assert "unknown_finding" == code(fix(ctx, cp2, [Ecto.UUID.generate()]))

        # A finding of a round with no verdict yet.
        %{key: key} = placed!(ctx, checkpoint_id: cp2.id)
        open = finding!(ctx, key, %{"introduced_by" => "none"})
        cp3 = checkpoint(ctx, 3)
        assert "unknown_finding" == code(fix(ctx, cp3, [open.id]))
      end)
    end

    test "a fix needs a checkpoint", ctx do
      unboxed(fn ->
        assert "fix_checkpoint_required" ==
                 code(
                   Reviews.record_fix(ctx.tenant_id, ctx.story.id, ctx.impl_key, %{
                     "claim_epoch" => current_epoch(ctx),
                     "finding_ids" => [ctx.f1.id],
                     "idempotency_key" => "n",
                     "body" => "b"
                   })
                 )
      end)
    end
  end

  # --- AC-45.3.6 / AC-45.3.7: the ceiling -------------------------------------------------

  describe "the round ceiling (TC-45.3.5)" do
    test "a round-2 finding introduced by a round-1 fix checkpoint opens round 3, never 4",
         ctx do
      unboxed(fn ->
        %{cp2: cp2} = round_one_fixed(ctx)

        %{key: r2} = placed!(ctx, checkpoint_id: cp2.id)
        assert placed_round(r2, ctx) == 2
        finding!(ctx, r2, %{"introduced_by" => cp2.id, "severity" => "high"})
        assert %{entry: _, escalation: nil} = verdict!(ctx, r2)

        assert %{completed: 2, next_round: 3} = Reviews.rounds(ctx.tenant_id, ctx.story.id)

        %{key: r3, review: review3} = placed!(ctx)
        assert review3.round == 3
        finding!(ctx, r3, %{"introduced_by" => "none", "severity" => "medium"})
        assert %{escalation: %Entry{kind: :escalation}} = verdict!(ctx, r3)

        assert %{completed: 3, next_round: nil, ceiling_reached: true} =
                 Reviews.rounds(ctx.tenant_id, ctx.story.id)

        refusal = place(ctx)
        assert "review_ceiling_reached" == code(refusal)
        refute inspect(refusal) =~ "self_review_blocked"
      end)
    end

    test "a material round-2 finding NOT introduced by a fix escalates with review_ceiling",
         ctx do
      unboxed(fn ->
        %{cp2: cp2} = round_one_fixed(ctx)
        epoch = current_epoch(ctx)

        stage =
          fixture(:story_stage, %{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            stage: :implementing,
            claim_epoch: epoch
          })

        %{key: r2} = placed!(ctx, checkpoint_id: cp2.id)
        finding!(ctx, r2, %{"introduced_by" => "none", "severity" => "critical"})

        assert %{escalation: %Entry{} = escalation} = verdict!(ctx, r2)
        assert escalation.kind == :escalation
        assert escalation.body =~ "review_ceiling"

        assert %{completed: 2, next_round: nil, ceiling_reached: true} =
                 Reviews.rounds(ctx.tenant_id, ctx.story.id)

        refusal = place(ctx)
        assert "review_ceiling_reached" == code(refusal)
        refute inspect(refusal) =~ "self_review_blocked"

        {:ok, row} =
          Repo.with_tenant(ctx.tenant_id, fn ->
            Repo.get!(Loopctl.Delivery.StoryStage, stage.id)
          end)

        assert row.stage == :escalated
      end)
    end

    test "a round 2 with only low findings reaches the ceiling without escalating",
         ctx do
      unboxed(fn ->
        %{cp2: cp2} = round_one_fixed(ctx)

        %{key: r2} = placed!(ctx, checkpoint_id: cp2.id)
        finding!(ctx, r2, %{"introduced_by" => "none", "severity" => "low"})
        assert %{escalation: nil} = verdict!(ctx, r2)

        assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      end)
    end

    test "a round-2 finding introduced by a checkpoint that carries NO round-1 fix does not open round 3",
         ctx do
      unboxed(fn ->
        %{cp1: cp1, cp2: cp2} = round_one_fixed(ctx)

        %{key: r2} = placed!(ctx, checkpoint_id: cp2.id)
        finding!(ctx, r2, %{"introduced_by" => cp1.id, "severity" => "high"})
        assert %{escalation: %Entry{}} = verdict!(ctx, r2)

        assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      end)
    end
  end

  # --- AC-45.3.2: the payload -------------------------------------------------------------

  describe "payload/3 (TC-45.3.2)" do
    test "the story, the checkpoint diff reference, the entries, each fix with its findings",
         ctx do
      unboxed(fn ->
        %{cp1: cp1, cp2: cp2, f1: f1, fix: fix} = round_one_fixed(ctx)
        %{review: review} = placed!(ctx, checkpoint_id: cp2.id)

        assert {:ok, payload} = Reviews.payload(ctx.tenant_id, ctx.story.id, review.id)

        assert payload.review.round == 2
        assert payload.story.id == ctx.story.id
        assert payload.story.title == ctx.story.title

        assert payload.checkpoint.commit_sha == cp2.commit_sha
        assert payload.checkpoint.parent_commit_sha == cp1.commit_sha
        assert payload.checkpoint.branch == "loop/#{ctx.story.id}"

        assert Enum.map(payload.entries, & &1.seq) ==
                 Enum.sort(Enum.map(payload.entries, & &1.seq))

        assert Enum.any?(payload.entries, &(&1.id == f1.id))

        assert [%{fix: %{id: fix_id}, findings: [%{id: finding_id}]}] = payload.fixes
        assert fix_id == fix.id
        assert finding_id == f1.id

        assert %{completed: 1, next_round: 2} = payload.rounds
      end)
    end

    test "tenant isolation: another tenant cannot read it", ctx do
      unboxed(fn ->
        checkpoint(ctx, 1)
        %{review: review} = placed!(ctx)
        other = fixture(:committed_tenant, %{trust_tier: :human_anchored})

        assert {:error, :not_found} = Reviews.payload(other.id, ctx.story.id, review.id)
      end)
    end
  end

  defp placed_round(key, ctx) do
    {:ok, dispatch} = Dispatches.dispatch_for_api_key(ctx.tenant_id, key.id)

    {:ok, round} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(
          from r in Loopctl.Threads.Review, where: r.dispatch_id == ^dispatch.id, select: r.round
        )
      end)

    round
  end

  defp mint!(tenant_id, attrs) do
    {:ok, %{dispatch: dispatch}} = Dispatches.create_dispatch(tenant_id, attrs)
    AdminRepo.get!(Loopctl.Auth.ApiKey, dispatch.api_key_id)
  end
end
