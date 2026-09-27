defmodule Loopctl.Threads.HumanFindingsTest do
  @moduledoc """
  US-45.7 (AC-45.7.3, PRD §6): a finding the tenant's human writes from the thread page —
  `Loopctl.Threads.record_human_finding/3` — and the standing it has in the review rules: it
  binds to a checkpoint, a fix can answer it, and it counts toward the round-3 decision and the
  ceiling for the round in progress when it was written.

  The halt refusal needs a tenant `AdminRepo` can see, so it is tested with the page in
  `LoopctlWeb.ThreadLiveTest`. Everything here is on the RLS `Repo` sandbox.
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
    [orchestrator, implementer, reviewer] = for _ <- 1..3, do: agent(tenant_id)
    root = fixture(:stage_dispatch, %{tenant_id: tenant_id, agent_id: orchestrator.id})

    session =
      fixture(:stage_dispatch, %{tenant_id: tenant_id, agent_id: implementer.id, parent: root})

    ctx = %{
      tenant_id: tenant_id,
      story: story,
      implementer: implementer,
      reviewer: reviewer,
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

  defp checkpoint(ctx, n) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(ctx.tenant_id, ctx.story.id,
        agent_id: ctx.implementer.id,
        claim_epoch: epoch(ctx),
        commit_sha: sha(n),
        tree_sha: @tree,
        author_principal: "agent:#{ctx.implementer.id}",
        actor_lineage: ctx.session.lineage_path
      )

    cp
  end

  defp human(ctx, checkpoint, attrs \\ %{}) do
    Threads.record_human_finding(
      ctx.tenant_id,
      ctx.story.id,
      Map.merge(
        %{
          "idempotency_key" => "nonce-#{System.unique_integer([:positive])}",
          "body" => "the retry re-posts the comment",
          "checkpoint_id" => checkpoint && checkpoint.id,
          "severity" => "high"
        },
        attrs
      )
    )
  end

  defp human!(ctx, checkpoint, attrs \\ %{}) do
    {:ok, entry, :created} = human(ctx, checkpoint, attrs)
    entry
  end

  defp placed!(ctx) do
    {:ok, review, :created} =
      Threads.record_review(ctx.tenant_id, ctx.story.id,
        dispatch_id: Ecto.UUID.generate(),
        runner_id: ctx.reviewer.id,
        agent_id: ctx.reviewer.id,
        placed_by: "api_key:test"
      )

    review
  end

  defp judge!(ctx, review, attrs) do
    {:ok, written, :created} =
      Threads.record_judgement(
        ctx.tenant_id,
        ctx.story.id,
        review.dispatch_id,
        Map.merge(%{"idempotency_key" => "j-#{System.unique_integer([:positive])}"}, attrs),
        runner_id: review.runner_id,
        author_principal: "agent:#{review.agent_id}"
      )

    written
  end

  defp verdict!(ctx, review), do: judge!(ctx, review, %{"kind" => "verdict", "body" => "done"})

  defp agent_finding!(ctx, review, attrs) do
    judge!(
      ctx,
      review,
      Map.merge(%{"kind" => "finding", "body" => "b", "severity" => "low"}, attrs)
    ).entry
  end

  defp fix(ctx, checkpoint, finding_ids) do
    Threads.record_fix(
      ctx.tenant_id,
      ctx.story.id,
      %{
        "checkpoint_id" => checkpoint.id,
        "finding_ids" => finding_ids,
        "idempotency_key" => "x-#{System.unique_integer([:positive])}",
        "body" => "fixed"
      },
      agent_id: ctx.implementer.id,
      claim_epoch: epoch(ctx),
      author_principal: "agent:#{ctx.implementer.id}",
      actor_lineage: []
    )
  end

  defp code({:error, {_status, code, _message}}), do: code
  defp code(other), do: other

  # --- recording -------------------------------------------------------------------------

  describe "record_human_finding/3" do
    test "binds to a checkpoint, as the human principal with an EMPTY lineage, and chains it",
         ctx do
      cp = checkpoint(ctx, 1)
      entry = human!(ctx, cp, %{"location" => "lib/a.ex:3"})

      assert entry.kind == :finding and entry.checkpoint_id == cp.id
      assert entry.author_principal == Threads.human_principal()
      assert entry.author_principal == "human:webauthn"
      assert entry.review_id == nil and entry.dispatch_id == nil
      assert entry.severity == :high and entry.location == "lib/a.ex:3"

      {:ok, chained} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.one(
            from c in ChainEntry,
              where: c.action == "thread_finding_recorded",
              where: fragment("?->>'thread_entry_id' = ?", c.payload, ^entry.id)
          )
        end)

      assert chained.actor_lineage == []
      assert chained.payload["author_principal"] == "human:webauthn"
    end

    test "the same form submitted twice is ONE entry; a different finding under its key is refused",
         ctx do
      cp = checkpoint(ctx, 1)
      attrs = %{"idempotency_key" => "form-nonce-1"}

      assert {:ok, entry, :created} = human(ctx, cp, attrs)
      assert {:ok, ^entry, :existing} = human(ctx, cp, attrs)

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               human(ctx, cp, Map.put(attrs, "body", "something else"))

      {:ok, count} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.aggregate(from(e in Entry, where: e.kind == :finding), :count)
        end)

      assert count == 1
    end

    test "only on a claimant checkpoint of the current, held claim", ctx do
      cp = checkpoint(ctx, 1)

      assert "finding_checkpoint_required" == code(human(ctx, nil))

      assert "finding_checkpoint_not_current_claim" ==
               code(human(ctx, nil, %{"checkpoint_id" => Ecto.UUID.generate()}))

      set_story(ctx, assigned_agent_id: nil)
      assert "finding_checkpoint_not_current_claim" == code(human(ctx, cp))

      set_story(ctx, assigned_agent_id: ctx.implementer.id, claim_epoch: epoch(ctx) + 1)
      assert "finding_checkpoint_not_current_claim" == code(human(ctx, cp))
    end

    test "a base update is loopctl's merge, not work a finding binds to", ctx do
      cp = checkpoint(ctx, 1)

      base =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          seq: 2,
          kind: :base_update,
          claim_epoch: epoch(ctx),
          commit_sha: sha(99),
          parent_checkpoint_id: cp.id
        })

      assert "finding_checkpoint_not_current_claim" == code(human(ctx, base))
    end

    test "severity, location and body meet a reviewer's rules", ctx do
      cp = checkpoint(ctx, 1)

      assert "invalid_severity" == code(human(ctx, cp, %{"severity" => "urgent"}))

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               human(ctx, cp, %{"body" => "token ghp_" <> String.duplicate("a", 36)})

      assert {:error, %Ecto.Changeset{}} = human(ctx, cp, %{"body" => ""})
    end

    test "introduced_by: refused before any round completes, required after, and bounded",
         ctx do
      cp1 = checkpoint(ctx, 1)
      assert "introduced_by_not_allowed" == code(human(ctx, cp1, %{"introduced_by" => "none"}))

      r1 = placed!(ctx)
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)

      assert "introduced_by_required" == code(human(ctx, cp2))
      assert {:ok, _, :created} = human(ctx, cp2, %{"introduced_by" => "none"})
      assert {:ok, _, :created} = human(ctx, cp2, %{"introduced_by" => cp1.id})
      assert "introduced_by_invalid" == code(human(ctx, cp1, %{"introduced_by" => cp2.id}))
    end

    test "tenant isolation: another tenant's story is not found", ctx do
      cp = checkpoint(ctx, 1)
      other = fixture(:stage_tenant, %{})

      assert {:error, :not_found} =
               Threads.record_human_finding(other.id, ctx.story.id, %{
                 "idempotency_key" => "k",
                 "body" => "b",
                 "checkpoint_id" => cp.id,
                 "severity" => "low"
               })
    end

    test "the schema admits a review-less finding from the human principal and no one else",
         ctx do
      cp = checkpoint(ctx, 1)

      insert = fn author ->
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.insert!(%Entry{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            seq: 100 + System.unique_integer([:positive]),
            kind: :finding,
            author_principal: author,
            idempotency_key: "raw-#{System.unique_integer([:positive])}",
            body: "b",
            checkpoint_id: cp.id,
            severity: :low
          })
        end)
      end

      assert {:ok, %Entry{}} = insert.("human:webauthn")

      assert_raise Ecto.ConstraintError, ~r/thread_entries_judgement_shape/, fn ->
        insert.("agent:#{ctx.implementer.id}")
      end
    end
  end

  # --- standing (PRD §6) -----------------------------------------------------------------

  describe "a human finding's standing in the rounds" do
    test "a fix answers it, on a later checkpoint of the claim", ctx do
      cp1 = checkpoint(ctx, 1)
      finding = human!(ctx, cp1)
      cp2 = checkpoint(ctx, 2)

      assert {:ok, fix, :created} = fix(ctx, cp2, [finding.id])
      assert fix.finding_ids == [finding.id]
      assert "fix_checkpoint_not_after_findings" == code(fix(ctx, cp1, [finding.id]))
    end

    test "a material one written during the ceiling round escalates it", ctx do
      checkpoint(ctx, 1)
      r1 = placed!(ctx)
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)

      r2 = placed!(ctx)
      human!(ctx, cp2, %{"introduced_by" => "none", "severity" => "critical"})

      assert %{escalation: %Entry{kind: :escalation} = escalation} = verdict!(ctx, r2)
      assert escalation.body =~ "1 material finding"
    end

    test "one on the round-2 checkpoint introduced by a round-1 fix opens round 3", ctx do
      cp1 = checkpoint(ctx, 1)
      r1 = placed!(ctx)
      f1 = agent_finding!(ctx, r1, %{})
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)
      {:ok, _fix, :created} = fix(ctx, cp2, [f1.id])

      r2 = placed!(ctx)
      human!(ctx, cp2, %{"introduced_by" => cp2.id, "severity" => "medium"})
      assert %{escalation: nil} = verdict!(ctx, r2)

      assert %{completed: 2, next_round: 3} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
      assert cp1.seq < cp2.seq
    end

    test "one written AFTER the round's verdict counts for neither decision", ctx do
      checkpoint(ctx, 1)
      r1 = placed!(ctx)
      f1 = agent_finding!(ctx, r1, %{})
      verdict!(ctx, r1)
      cp2 = checkpoint(ctx, 2)
      {:ok, _fix, :created} = fix(ctx, cp2, [f1.id])

      r2 = placed!(ctx)
      assert %{escalation: nil} = verdict!(ctx, r2)
      assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)

      human!(ctx, cp2, %{"introduced_by" => cp2.id, "severity" => "critical"})
      assert %{next_round: nil} = Reviews.rounds(ctx.tenant_id, ctx.story.id)
    end
  end
end
