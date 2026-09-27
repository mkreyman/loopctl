defmodule Loopctl.Threads.ReviewsTest do
  @moduledoc """
  US-45.3: the review rules and the three narrow `Loopctl.Threads` entry points that apply
  them — `record_review/3`, `record_judgement/5` and `record_fix/4`. The socket wiring, the
  placement and the custody halt are in `Loopctl.Delivery.ReviewPlacementTest`; the durable
  stage move in `Loopctl.Workers.ReviewCeilingWorkerTest`.

  Everything here lives on the RLS `Repo` sandbox (`fixture(:stage_story)` and friends), so it
  runs async.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.Threads.Reviews
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @tree String.duplicate("c", 40)

  setup do
    story = fixture(:stage_story, %{claim_epoch: 3, agent_status: :implementing})
    tenant_id = story.tenant_id
    [orchestrator, implementer, reviewer, spare] = for _ <- 1..4, do: agent(tenant_id)
    root = fixture(:stage_dispatch, %{tenant_id: tenant_id, agent_id: orchestrator.id})

    session =
      fixture(:stage_dispatch, %{tenant_id: tenant_id, agent_id: implementer.id, parent: root})

    ctx = %{
      tenant_id: tenant_id,
      story: story,
      orchestrator: orchestrator,
      implementer: implementer,
      reviewer: reviewer,
      spare: spare,
      root: root,
      session: session
    }

    set_story(ctx,
      assigned_agent_id: implementer.id,
      implementer_dispatch_id: session.id,
      claimed_until: DateTime.add(DateTime.utc_now(), 3_600)
    )

    {:ok, ctx}
  end

  # --- helpers ---------------------------------------------------------------------------

  defp agent(tenant_id), do: fixture(:stage_agent, %{tenant_id: tenant_id})

  defp sha(n), do: n |> Integer.to_string(16) |> String.pad_leading(40, "0")

  defp set_story(ctx, fields) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in Story, where: s.id == ^ctx.story.id) |> Repo.update_all(set: fields)
      end)
  end

  defp epoch(ctx) do
    {:ok, epoch} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^ctx.story.id, select: s.claim_epoch)
      end)

    epoch
  end

  defp checkpoint(ctx, n, overrides \\ []) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(
        ctx.tenant_id,
        ctx.story.id,
        Keyword.merge(
          [
            agent_id: ctx.implementer.id,
            claim_epoch: epoch(ctx),
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

  defp place(ctx, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, ctx.reviewer.id)

    Threads.record_review(ctx.tenant_id, ctx.story.id,
      dispatch_id: Keyword.get(opts, :dispatch_id, Ecto.UUID.generate()),
      runner_id: Keyword.get(opts, :runner_id, runner_of(agent_id)),
      agent_id: agent_id,
      placed_by: "api_key:test"
    )
  end

  # One stable runner id per agent, so a review's runner is the one its judgements come from.
  defp runner_of(agent_id), do: agent_id

  defp placed!(ctx, opts \\ []) do
    {:ok, review, :created} = place(ctx, opts)
    review
  end

  defp judge(ctx, review, attrs, opts \\ []) do
    Threads.record_judgement(
      ctx.tenant_id,
      ctx.story.id,
      Keyword.get(opts, :dispatch_id, review.dispatch_id),
      attrs,
      Keyword.merge(
        [runner_id: review.runner_id, author_principal: "agent:#{review.agent_id}"],
        opts
      )
    )
  end

  defp finding(ctx, review, attrs \\ %{}, opts \\ []) do
    judge(
      ctx,
      review,
      Map.merge(
        %{
          "kind" => "finding",
          "idempotency_key" => "f-#{System.unique_integer([:positive])}",
          "body" => "the lock is taken after the chain",
          "severity" => "high"
        },
        attrs
      ),
      opts
    )
  end

  defp finding!(ctx, review, attrs \\ %{}) do
    {:ok, %{entry: entry}, :created} = finding(ctx, review, attrs)
    entry
  end

  defp verdict(ctx, review, key \\ nil) do
    judge(ctx, review, %{
      "kind" => "verdict",
      "idempotency_key" => key || "v-#{System.unique_integer([:positive])}",
      "body" => "round done"
    })
  end

  defp verdict!(ctx, review, key \\ nil) do
    {:ok, written, :created} = verdict(ctx, review, key)
    written
  end

  defp fix(ctx, checkpoint, finding_ids, attrs \\ %{}, opts \\ []) do
    Threads.record_fix(
      ctx.tenant_id,
      ctx.story.id,
      Map.merge(
        %{
          "checkpoint_id" => checkpoint.id,
          "finding_ids" => finding_ids,
          "idempotency_key" => "x-#{System.unique_integer([:positive])}",
          "body" => "moved the lock"
        },
        attrs
      ),
      Keyword.merge(
        [
          agent_id: ctx.implementer.id,
          claim_epoch: epoch(ctx),
          author_principal: "agent:#{ctx.implementer.id}",
          actor_lineage: []
        ],
        opts
      )
    )
  end

  defp code({:error, {_status, code, _message}}), do: code
  defp code(other), do: other

  # Round 1 on checkpoint 1 with one finding, and its fix on checkpoint 2.
  defp round_one_fixed(ctx, severity \\ "high") do
    cp1 = checkpoint(ctx, 1)
    r1 = placed!(ctx)
    f1 = finding!(ctx, r1, %{"severity" => severity})
    verdict!(ctx, r1)
    cp2 = checkpoint(ctx, 2)
    {:ok, fix, :created} = fix(ctx, cp2, [f1.id])
    %{cp1: cp1, cp2: cp2, r1: r1, f1: f1, fix: fix}
  end

  # --- placement (AC-45.3.1) -------------------------------------------------------------

  describe "record_review/3" do
    test "records round 1 on the latest checkpoint of the current claim, and chains it", ctx do
      _cp1 = checkpoint(ctx, 1)
      cp2 = checkpoint(ctx, 2)

      review = placed!(ctx)

      assert review.round == 1
      assert review.checkpoint_id == cp2.id
      assert review.claim_epoch == epoch(ctx)
      assert review.agent_id == ctx.reviewer.id

      {:ok, actions} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.all(
            from c in ChainEntry,
              where: c.tenant_id == ^ctx.tenant_id and c.entity_id == ^ctx.story.id,
              select: c.action
          )
        end)

      assert "thread_review_placed" in actions
    end

    test "a checkpoint an ENDED claim recorded is not reviewable", ctx do
      assert "no_checkpoint" == code(place(ctx))

      checkpoint(ctx, 1)
      set_story(ctx, claim_epoch: epoch(ctx) + 1)

      assert "no_checkpoint" == code(place(ctx))
    end

    test "a claim no dispatch made has no implementer to be separate from", ctx do
      checkpoint(ctx, 1)
      set_story(ctx, implementer_dispatch_id: nil)
      assert "implementer_dispatch_required" == code(place(ctx))
    end

    test "never for the claimant, a checkpoint recorder, or an agent on the implementer's chain",
         ctx do
      checkpoint(ctx, 1)

      assert "reviewer_not_separate" == code(place(ctx, agent_id: ctx.implementer.id))

      checkpoint(ctx, 2, author_principal: "agent:#{ctx.spare.id}")
      assert "reviewer_not_separate" == code(place(ctx, agent_id: ctx.spare.id))

      # ABOVE the implementer: the orchestrator whose dispatch parents it.
      assert "reviewer_not_separate" == code(place(ctx, agent_id: ctx.orchestrator.id))

      # BELOW the implementer.
      below = agent(ctx.tenant_id)

      fixture(:stage_dispatch, %{
        tenant_id: ctx.tenant_id,
        agent_id: below.id,
        parent: ctx.session
      })

      assert "reviewer_not_separate" == code(place(ctx, agent_id: below.id))

      # A SIBLING of the implementer is separate.
      sibling = agent(ctx.tenant_id)

      fixture(:stage_dispatch, %{tenant_id: ctx.tenant_id, agent_id: sibling.id, parent: ctx.root})

      assert {:ok, _review, :created} = place(ctx, agent_id: sibling.id)
    end

    test "idempotent on the dispatch id, and the id is one placement's", ctx do
      checkpoint(ctx, 1)
      dispatch_id = Ecto.UUID.generate()

      {:ok, review, :created} = place(ctx, dispatch_id: dispatch_id)
      assert {:ok, ^review, :existing} = place(ctx, dispatch_id: dispatch_id)

      assert "dispatch_id_conflict" ==
               code(place(ctx, dispatch_id: dispatch_id, runner_id: Ecto.UUID.generate()))
    end

    test "tenant isolation: another tenant's story is not found", ctx do
      checkpoint(ctx, 1)
      other = fixture(:stage_story, %{claim_epoch: 1})

      assert {:error, :not_found} =
               Threads.record_review(ctx.tenant_id, other.id,
                 dispatch_id: Ecto.UUID.generate(),
                 runner_id: Ecto.UUID.generate(),
                 agent_id: ctx.reviewer.id,
                 placed_by: "t"
               )
    end
  end

  # --- judgements (AC-45.3.3 / AC-45.3.4) ------------------------------------------------

  describe "record_judgement/5" do
    test "only the review's own dispatch, from its own runner, judges (TC-45.3.1)", ctx do
      cp = checkpoint(ctx, 1)
      review = placed!(ctx)

      # Another runner naming this dispatch, and another dispatch altogether.
      assert {:error, :unknown_review} =
               finding(ctx, review, %{}, runner_id: Ecto.UUID.generate())

      assert {:error, :unknown_review} =
               finding(ctx, review, %{}, dispatch_id: Ecto.UUID.generate())

      assert {:ok, %{entry: entry}, :created} =
               finding(ctx, review, %{"location" => "lib/a.ex:10", "severity" => "CRITICAL"})

      assert entry.kind == :finding
      assert entry.review_id == review.id
      assert entry.checkpoint_id == cp.id
      assert entry.severity == :critical
      assert entry.location == "lib/a.ex:10"
      assert entry.author_principal == "agent:#{ctx.reviewer.id}"
    end

    test "a judgement is a finding or a verdict, never a message or a fix", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)

      assert {:error, :unprocessable_entity, _} =
               judge(ctx, review, %{"kind" => "fix", "idempotency_key" => "k", "body" => "b"})
    end

    test "severity is one of four; a credential in the location is refused", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)

      assert "invalid_severity" == code(finding(ctx, review, %{"severity" => "urgent"}))

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               finding(ctx, review, %{
                 "location" => "ghp_" <> String.duplicate("a", 36)
               })
    end

    test "introduced_by is refused in round 1, required after it, and canonical (TC-45.3.4)",
         ctx do
      %{cp1: cp1, cp2: cp2} = round_one_fixed(ctx)
      review = placed!(ctx)
      assert review.checkpoint_id == cp2.id

      assert "introduced_by_required" == code(finding(ctx, review))
      assert "introduced_by_invalid" == code(finding(ctx, review, %{"introduced_by" => "nope"}))

      cp3 = checkpoint(ctx, 3)

      assert "introduced_by_invalid" ==
               code(finding(ctx, review, %{"introduced_by" => cp3.id}))

      assert {:ok, %{entry: %{introduced_by: "none"}}, :created} =
               finding(ctx, review, %{"introduced_by" => " NONE "})

      assert {:ok, %{entry: %{introduced_by: canonical}}, :created} =
               finding(ctx, review, %{"introduced_by" => String.upcase(cp1.id)})

      assert canonical == cp1.id
    end

    test "round 1 refuses introduced_by", ctx do
      cp = checkpoint(ctx, 1)
      review = placed!(ctx)

      assert "introduced_by_not_allowed" ==
               code(finding(ctx, review, %{"introduced_by" => cp.id}))
    end

    test "one verdict per review; a resend is its row; nothing after it (TC-45.3.3)", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)

      assert {:ok, %{entry: verdict, escalation: nil}, :created} = verdict(ctx, review, "v1")
      assert {:ok, %{entry: ^verdict}, :existing} = verdict(ctx, review, "v1")

      assert "review_closed" == code(verdict(ctx, review, "v2"))
      assert "review_closed" == code(finding(ctx, review))
      assert %{completed: 1, next_round: 2} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end

    test "a review that ends without a verdict uses no round", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      finding!(ctx, review)

      assert %{completed: 0, next_round: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      assert {:ok, %{round: 1}, :created} = place(ctx, agent_id: ctx.spare.id)
    end

    test "two reviews of one round cannot both complete it", ctx do
      checkpoint(ctx, 1)
      first = placed!(ctx)
      second = placed!(ctx, agent_id: ctx.spare.id)

      verdict!(ctx, first)

      assert "review_round_superseded" == code(finding(ctx, second))
      assert "review_round_superseded" == code(verdict(ctx, second))
      assert %{completed: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end

    test "a review whose claim ended writes nothing more, and nothing it said counts", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      finding!(ctx, review)

      # A force-unclaim clears the claimant and leaves the epoch where it was.
      set_story(ctx, assigned_agent_id: nil)
      assert "review_claim_ended" == code(finding(ctx, review))
      assert "review_claim_ended" == code(verdict(ctx, review))
      assert "review_claim_ended" == code(place(ctx, agent_id: ctx.spare.id))

      # A new claim moves the epoch: the review belongs to the one before it.
      set_story(ctx, assigned_agent_id: ctx.implementer.id, claim_epoch: epoch(ctx) + 1)
      assert "review_claim_ended" == code(verdict(ctx, review))

      {:ok, kinds} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.all(from e in Entry, where: e.review_id == ^review.id, select: e.kind)
        end)

      assert kinds == [:finding]
    end

    test "separation is decided again on every judgement", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)

      # The claim moves to the reviewer's agent after the placement.
      set_story(ctx, assigned_agent_id: ctx.reviewer.id)
      assert "reviewer_not_separate" == code(finding(ctx, review))

      # Or the reviewer's agent gains a dispatch below the implementer.
      set_story(ctx, assigned_agent_id: ctx.implementer.id)

      fixture(:stage_dispatch, %{
        tenant_id: ctx.tenant_id,
        agent_id: ctx.reviewer.id,
        parent: ctx.session
      })

      assert "reviewer_not_separate" == code(finding(ctx, review))
    end

    test "a dispatch no longer accepted answers a resend and writes nothing new", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      attrs = %{"idempotency_key" => "same", "severity" => "low"}
      {:ok, %{entry: entry}, :created} = finding(ctx, review, attrs)

      assert {:ok, %{entry: ^entry}, :existing} =
               finding(ctx, review, attrs, replay_only: true)

      assert {:error, :dispatch_not_accepted} =
               finding(ctx, review, %{"idempotency_key" => "new"}, replay_only: true)
    end

    test "idempotency is the review's: one agent, two rounds, one key, both accepted", ctx do
      checkpoint(ctx, 1)
      r1 = placed!(ctx)
      {:ok, %{entry: one}, :created} = finding(ctx, r1, %{"idempotency_key" => "k"})
      %{entry: v1} = verdict!(ctx, r1, "v")
      r2 = placed!(ctx)

      assert {:ok, %{entry: two}, :created} =
               finding(ctx, r2, %{"idempotency_key" => "k", "introduced_by" => "none"})

      assert {:ok, %{entry: v2}, :created} = verdict(ctx, r2, "v")
      assert two.id != one.id and v2.id != v1.id

      # A message by the same agent under the same key is no collision either.
      assert {:ok, %Entry{kind: :message}, :created} =
               Threads.record_entry(
                 ctx.tenant_id,
                 ctx.story.id,
                 %{"kind" => "message", "idempotency_key" => "k", "body" => "note"},
                 author_principal: "agent:#{ctx.reviewer.id}",
                 actor_lineage: []
               )

      assert "idempotency_key_reused" ==
               code(finding(ctx, r2, %{"idempotency_key" => "k", "severity" => "low"}))
    end

    test "the chain pins what the rounds are computed from", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      finding!(ctx, review)

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
    end
  end

  # --- fixes (AC-45.3.5) -----------------------------------------------------------------

  describe "record_fix/4" do
    setup ctx do
      cp1 = checkpoint(ctx, 1)
      review = placed!(ctx)
      f1 = finding!(ctx, review)
      verdict!(ctx, review)
      {:ok, cp1: cp1, f1: f1}
    end

    test "the claimant names a finding, on a later checkpoint of its claim", ctx do
      cp2 = checkpoint(ctx, 2)

      assert {:ok, entry, :created} = fix(ctx, cp2, [String.upcase(ctx.f1.id)])
      assert entry.kind == :fix and entry.finding_ids == [ctx.f1.id]
    end

    test "on the checkpoint its finding was found in, or an older one, it is refused", ctx do
      assert "fix_checkpoint_not_after_findings" == code(fix(ctx, ctx.cp1, [ctx.f1.id]))
    end

    test "under an ended claim, or on an ended claim's checkpoint, it is refused", ctx do
      cp2 = checkpoint(ctx, 2)
      old = epoch(ctx)
      set_story(ctx, claim_epoch: old + 1)

      assert {:error, :stale_claim_epoch} = fix(ctx, cp2, [ctx.f1.id], %{}, claim_epoch: old)

      assert "fix_checkpoint_not_current_claim" ==
               code(fix(ctx, cp2, [ctx.f1.id], %{}, claim_epoch: old + 1))
    end

    test "another agent, and a lapsed lease, are refused", ctx do
      cp2 = checkpoint(ctx, 2)

      assert {:error, :not_claimant} = fix(ctx, cp2, [ctx.f1.id], %{}, agent_id: ctx.spare.id)

      set_story(ctx, claimed_until: DateTime.add(DateTime.utc_now(), -60))
      assert {:error, :claim_not_live} = fix(ctx, cp2, [ctx.f1.id])
    end

    test "findings must be this story's, of completed rounds, and a checkpoint is required",
         ctx do
      cp2 = checkpoint(ctx, 2)

      assert "finding_ids_required" == code(fix(ctx, cp2, []))
      assert "unknown_finding" == code(fix(ctx, cp2, [Ecto.UUID.generate()]))

      assert "fix_checkpoint_required" ==
               code(fix(ctx, cp2, [ctx.f1.id], %{"checkpoint_id" => nil}))

      review = placed!(ctx, agent_id: ctx.spare.id)
      open = finding!(ctx, review, %{"introduced_by" => "none"})
      cp3 = checkpoint(ctx, 3)
      assert "unknown_finding" == code(fix(ctx, cp3, [open.id]))
    end

    test "a resend is its row", ctx do
      cp2 = checkpoint(ctx, 2)
      attrs = %{"idempotency_key" => "fx"}
      {:ok, entry, :created} = fix(ctx, cp2, [ctx.f1.id], attrs)
      assert {:ok, ^entry, :existing} = fix(ctx, cp2, [ctx.f1.id], attrs)
    end
  end

  # --- the ceiling (AC-45.3.6 / AC-45.3.7) -----------------------------------------------

  describe "the round ceiling (TC-45.3.5)" do
    test "a round-2 finding introduced by a round-1 fix checkpoint opens round 3, never 4", ctx do
      %{cp2: cp2} = round_one_fixed(ctx)

      r2 = placed!(ctx)
      assert r2.round == 2
      finding!(ctx, r2, %{"introduced_by" => cp2.id})
      assert %{escalation: nil} = verdict!(ctx, r2)
      assert %{completed: 2, next_round: 3} = Reviews.rounds(ctx.tenant_id, ctx.story.id)

      r3 = placed!(ctx)
      assert r3.round == 3
      finding!(ctx, r3, %{"introduced_by" => "none", "severity" => "medium"})
      assert %{escalation: %Entry{kind: :escalation} = esc} = verdict!(ctx, r3)
      assert esc.body =~ "review_ceiling"

      refusal = place(ctx)
      assert "review_ceiling_reached" == code(refusal)
      refute inspect(refusal) =~ "self_review_blocked"
    end

    test "a material round-2 finding not introduced by a fix reaches the ceiling and escalates",
         ctx do
      %{cp1: cp1} = round_one_fixed(ctx)

      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => cp1.id, "severity" => "critical"})
      assert %{escalation: %Entry{}} = verdict!(ctx, r2)

      assert %{completed: 2, next_round: nil, ceiling_reached: true} =
               Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end

    test "a round 2 with only low findings reaches the ceiling without escalating", ctx do
      round_one_fixed(ctx)
      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => "none", "severity" => "low"})
      assert %{escalation: nil} = verdict!(ctx, r2)
      assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end

    test "a fix written while round 2 streams its findings does not open round 3", ctx do
      checkpoint(ctx, 1)
      r1 = placed!(ctx)
      f1 = finding!(ctx, r1, %{"severity" => "low"})
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)

      # Round 2 is placed on cp2 BEFORE any fix exists; a fix on cp2 lands mid-round, and a
      # round-2 finding names cp2 as where its defect came in.
      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => cp2.id, "severity" => "low"})
      assert {:ok, _fix, :created} = fix(ctx, cp2, [f1.id])
      verdict!(ctx, r2)

      assert %{next_round: nil, ceiling_reached: true} =
               Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end

    test "a resent verdict answers the escalation its first delivery recorded", ctx do
      round_one_fixed(ctx)
      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => "none", "severity" => "high"})

      assert {:ok, %{escalation: %Entry{id: esc_id}}, :created} = verdict(ctx, r2, "v-final")

      assert {:ok, %{escalation: %Entry{id: ^esc_id}}, :existing} =
               verdict(ctx, r2, "v-final")
    end

    test "a finding of an earlier claim is unknown_finding to this claim's fix", ctx do
      %{f1: f1} = round_one_fixed(ctx)

      # The story is released and claimed again; the new claim records its own checkpoint.
      set_story(ctx, claim_epoch: epoch(ctx) + 1)
      cp = checkpoint(ctx, 16)

      assert "unknown_finding" == code(fix(ctx, cp, [f1.id]))
    end

    test "rounds belong to a claim: a new claim starts at round 1 after a ceiling", ctx do
      %{cp1: cp1} = round_one_fixed(ctx)
      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => cp1.id, "severity" => "critical"})
      verdict!(ctx, r2)
      assert "review_ceiling_reached" == code(place(ctx))

      # The story is released and claimed again: rewritten work.
      set_story(ctx, claim_epoch: epoch(ctx) + 1)
      checkpoint(ctx, 16)

      assert %{completed: 0, next_round: 1} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      assert {:ok, %{round: 1}, :created} = place(ctx)
    end

    test "a fix attached AFTER the round-2 verdict does not make round 3 placeable", ctx do
      checkpoint(ctx, 1)
      r1 = placed!(ctx)
      f1 = finding!(ctx, r1, %{"severity" => "low"})
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)

      r2 = placed!(ctx)
      finding!(ctx, r2, %{"introduced_by" => cp2.id, "severity" => "low"})
      verdict!(ctx, r2)
      assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)

      assert {:ok, _fix, :created} = fix(ctx, cp2, [f1.id])
      assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      assert "review_ceiling_reached" == code(place(ctx))
    end
  end

  # --- the payload (AC-45.3.2) -----------------------------------------------------------

  describe "payload/3 (TC-45.3.2)" do
    test "the story, the checkpoint diff reference, the entries, each fix with its findings",
         ctx do
      %{cp1: cp1, cp2: cp2, f1: f1, fix: fix} = round_one_fixed(ctx)
      review = placed!(ctx)

      assert {:ok, payload} = Reviews.payload(ctx.tenant_id, ctx.story.id, review.id)

      assert payload.review.round == 2
      assert payload.story.id == ctx.story.id
      assert payload.checkpoint.commit_sha == cp2.commit_sha
      assert payload.checkpoint.parent_commit_sha == cp1.commit_sha
      assert Enum.any?(payload.entries, &(&1.id == f1.id))
      assert [%{fix: %{id: fix_id}, findings: [%{id: finding_id}]}] = payload.fixes
      assert fix_id == fix.id and finding_id == f1.id
      refute payload.fixes_truncated
    end

    test "carries the latest fixes only, and says when it cut older ones", ctx do
      %{cp2: cp2, f1: f1} = round_one_fixed(ctx)
      review = placed!(ctx)

      for _ <- 1..Reviews.max_payload_fixes(), do: {:ok, _, :created} = fix(ctx, cp2, [f1.id])

      {:ok, payload} = Reviews.payload(ctx.tenant_id, ctx.story.id, review.id)
      assert payload.fixes_truncated
      assert length(payload.fixes) == Reviews.max_payload_fixes()
      assert Enum.all?(payload.fixes, &(hd(&1.findings).id == f1.id))
    end

    test "tenant isolation: another tenant cannot read it", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      other = fixture(:stage_story, %{claim_epoch: 1})

      assert {:error, :not_found} = Reviews.payload(other.tenant_id, ctx.story.id, review.id)
    end
  end

  # --- the database's own guards ---------------------------------------------------------

  describe "the schema" do
    test "holds a review to one verdict", ctx do
      checkpoint(ctx, 1)
      review = placed!(ctx)
      %{entry: verdict} = verdict!(ctx, review)

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
    end

    test "refuses a fix that names no findings, NULL included", ctx do
      cp = checkpoint(ctx, 1)

      fix_row =
        %{kind: :fix, idempotency_key: "raw-fix", body: "b", checkpoint_id: cp.id}
        |> Entry.system_changeset()
        |> Ecto.Changeset.change(
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          seq: 1_000,
          author_principal: "agent:#{ctx.implementer.id}",
          finding_ids: nil
        )

      assert_raise Ecto.ConstraintError, ~r/thread_entries_judgement_shape/, fn ->
        Repo.with_tenant(ctx.tenant_id, fn -> Repo.insert(fix_row) end)
      end
    end
  end
end
