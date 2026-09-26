defmodule Loopctl.ThreadsTest do
  @moduledoc "US-45.1: the change-thread ledger."

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 3
  @sha1 String.duplicate("a", 40)
  @sha2 String.duplicate("b", 40)
  @tree String.duplicate("c", 40)

  defp claimed_story do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    agent = fixture(:stage_agent, %{tenant_id: story.tenant_id})
    reviewer = fixture(:stage_agent, %{tenant_id: story.tenant_id})

    {:ok, _} =
      Repo.with_tenant(story.tenant_id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [assigned_agent_id: agent.id])
      end)

    %{tenant_id: story.tenant_id, agent: agent, reviewer: reviewer, story: story}
  end

  defp checkpoint(ctx, sha \\ @sha1, overrides \\ []) do
    Threads.record_checkpoint(
      ctx.tenant_id,
      ctx.story.id,
      Keyword.merge(
        [
          agent_id: ctx.agent.id,
          claim_epoch: @epoch,
          commit_sha: sha,
          tree_sha: @tree,
          author_principal: "agent:#{ctx.agent.id}",
          actor_lineage: []
        ],
        overrides
      )
    )
  end

  # Written as the REVIEWER unless `as:` says otherwise.
  defp entry(ctx, attrs, opts \\ []) do
    author = Keyword.get(opts, :as, ctx.reviewer)

    Threads.record_entry(ctx.tenant_id, ctx.story.id, attrs,
      agent_id: author && author.id,
      claim_epoch: Keyword.get(opts, :claim_epoch),
      author_principal: if(author, do: "agent:#{author.id}", else: "api_key:human"),
      actor_lineage: []
    )
  end

  defp finding(cp, key \\ "f1"),
    do: %{
      "kind" => "finding",
      "idempotency_key" => key,
      "body" => "bug",
      "severity" => "high",
      "checkpoint_id" => cp.id
    }

  # A dispatch on the RLS repo, where `Threads` reads it; its id closes its own lineage.
  defp dispatch(tenant_id, ancestors) do
    id = Ecto.UUID.generate()

    {:ok, dispatch} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.insert!(%Loopctl.Dispatches.Dispatch{
          id: id,
          tenant_id: tenant_id,
          role: :agent,
          lineage_path: ancestors ++ [id],
          expires_at: DateTime.add(DateTime.utc_now(), 3600),
          created_at: DateTime.utc_now()
        })
      end)

    dispatch
  end

  describe "checkpoints" do
    test "the claimant records one, with a checkpoint entry beside it" do
      ctx = claimed_story()

      assert {:ok, cp, :created} = checkpoint(ctx)
      assert cp.seq == 1 and cp.claim_epoch == @epoch

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      assert [%{kind: :checkpoint, checkpoint_id: cp_id}] = thread.entries
      assert cp_id == cp.id
    end

    test "a stale epoch is refused and nothing is written" do
      ctx = claimed_story()

      assert {:error, :stale_claim_epoch} = checkpoint(ctx, @sha1, claim_epoch: @epoch - 1)

      assert {:ok, %{checkpoints: [], entries: []}} =
               Threads.get_thread(ctx.tenant_id, ctx.story.id)
    end

    test "another agent, or a key with no agent, is not the claimant" do
      ctx = claimed_story()

      assert {:error, :not_claimant} = checkpoint(ctx, @sha1, agent_id: ctx.reviewer.id)
      assert {:error, :not_claimant} = checkpoint(ctx, @sha1, agent_id: nil)
    end

    test "a new claim resuming at a recorded commit records it again under its own epoch" do
      ctx = claimed_story()
      {:ok, first, :created} = checkpoint(ctx)
      set_story(ctx, claim_epoch: @epoch + 1)

      assert {:ok, again, :created} = checkpoint(ctx, @sha1, claim_epoch: @epoch + 1)
      assert again.claim_epoch == @epoch + 1 and again.seq == first.seq + 1
      assert {:ok, ^again, :existing} = checkpoint(ctx, @sha1, claim_epoch: @epoch + 1)
    end

    test "a lapsed lease has ended the claim" do
      ctx = claimed_story()
      set_story(ctx, claimed_until: DateTime.add(DateTime.utc_now(), -60))

      assert {:error, :claim_not_live} = checkpoint(ctx)
    end

    test "a note must be non-empty and within the bound, and a resend must repeat it" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, msg} = checkpoint(ctx, @sha1, note: "")
      assert msg =~ "note"

      too_big = String.duplicate("n", Entry.max_body_bytes() + 1)
      assert {:error, :unprocessable_entity, msg} = checkpoint(ctx, @sha1, note: too_big)
      assert msg =~ "note"

      {:ok, cp, :created} = checkpoint(ctx, @sha1, note: "why")
      assert {:ok, ^cp, :existing} = checkpoint(ctx, @sha1, note: "why")
      assert {:ok, ^cp, :existing} = checkpoint(ctx)

      assert {:error, {:conflict, "checkpoint_conflict", _}} =
               checkpoint(ctx, @sha1, note: "another")
    end

    test "the same sha with a different tree is a conflict" do
      ctx = claimed_story()
      {:ok, _, :created} = checkpoint(ctx)

      assert {:error, {:conflict, "checkpoint_conflict", _}} =
               checkpoint(ctx, @sha1, tree_sha: String.duplicate("9", 40))
    end

    test "a note carrying a credential is refused" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               checkpoint(ctx, @sha1, note: "ghp_" <> String.duplicate("A", 36))
    end

    test "a resend is the checkpoint already recorded; the next one chains to it" do
      ctx = claimed_story()

      {:ok, first, :created} = checkpoint(ctx)
      assert {:ok, ^first, :existing} = checkpoint(ctx)

      {:ok, second, :created} = checkpoint(ctx, @sha2)
      assert second.seq == 2
      assert second.parent_checkpoint_id == first.id
    end

    test "a malformed sha is refused" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, _} = checkpoint(ctx, "HEAD")
      assert {:error, :unprocessable_entity, _} = checkpoint(ctx, @sha1, tree_sha: "abc")
    end
  end

  describe "entries" do
    test "a retry from the same author is the same entry; another author's key is distinct" do
      ctx = claimed_story()
      attrs = %{"kind" => "message", "idempotency_key" => "k1", "body" => "hello"}

      {:ok, e1, :created} = entry(ctx, attrs)
      assert {:ok, ^e1, :existing} = entry(ctx, attrs)
      assert {:ok, e2, :created} = entry(ctx, attrs, as: ctx.agent)
      assert e2.id != e1.id and e2.seq == e1.seq + 1
    end

    test "loopctl's own kinds are refused" do
      ctx = claimed_story()

      for kind <- ~w(checkpoint merge escalation) do
        assert {:error, :unprocessable_entity, _} =
                 entry(ctx, %{"kind" => kind, "idempotency_key" => kind, "body" => "x"})
      end
    end

    test "a body over the bound is refused" do
      ctx = claimed_story()
      body = String.duplicate("x", Entry.max_body_bytes() + 1)

      assert {:error, %Ecto.Changeset{} = cs} =
               entry(ctx, %{"kind" => "message", "idempotency_key" => "big", "body" => body})

      assert %{body: [_]} = errors_on(cs)
    end

    test "a body carrying a credential is refused and nothing is written" do
      ctx = claimed_story()
      token = "ghp_" <> String.duplicate("A", 36)

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               entry(ctx, %{"kind" => "message", "idempotency_key" => "s", "body" => token})

      assert {:ok, %{entries: []}} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
    end

    test "a finding names a checkpoint of this story and a severity" do
      ctx = claimed_story()
      other = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      {:ok, other_cp, :created} = checkpoint(other)

      assert {:error, :unprocessable_entity, _} =
               entry(ctx, Map.delete(finding(cp), "checkpoint_id"))

      assert {:error, :unprocessable_entity, _} = entry(ctx, Map.delete(finding(cp), "severity"))
      assert {:error, :unprocessable_entity, _} = entry(ctx, finding(other_cp))
      assert {:ok, _, :created} = entry(ctx, finding(cp))
    end

    test "a fix names its checkpoint and findings of this story" do
      ctx = claimed_story()
      {:ok, found_in, :created} = checkpoint(ctx)
      {:ok, f, :created} = entry(ctx, finding(found_in))
      {:ok, cp, :created} = checkpoint(ctx, @sha2)

      fix = %{"kind" => "fix", "idempotency_key" => "x1", "body" => "fixed"}
      as_claimant = [as: ctx.agent, claim_epoch: @epoch]

      assert {:error, :unprocessable_entity, _} =
               entry(ctx, Map.put(fix, "finding_ids", [f.id]), as_claimant)

      with_cp = Map.put(fix, "checkpoint_id", cp.id)
      assert {:error, :unprocessable_entity, msg} = entry(ctx, with_cp, as_claimant)
      assert msg == "a fix must name the findings it answers"

      assert {:error, :unprocessable_entity, _} =
               entry(
                 ctx,
                 Map.put(with_cp, "finding_ids", [f.id, Ecto.UUID.generate()]),
                 as_claimant
               )

      assert {:ok, _, :created} = entry(ctx, Map.put(with_cp, "finding_ids", [f.id]), as_claimant)
    end

    test "a fix is carried by a checkpoint of the current claim, newer than its findings" do
      ctx = claimed_story()
      {:ok, older, :created} = checkpoint(ctx)
      {:ok, found_in, :created} = checkpoint(ctx, @sha2)
      {:ok, f, :created} = entry(ctx, finding(found_in))

      fix = %{
        "kind" => "fix",
        "idempotency_key" => "x",
        "body" => "fixed",
        "finding_ids" => [f.id]
      }

      as_claimant = [as: ctx.agent, claim_epoch: @epoch]

      for stale <- [older, found_in] do
        assert {:error, :unprocessable_entity, msg} =
                 entry(ctx, Map.put(fix, "checkpoint_id", stale.id), as_claimant)

        assert msg =~ "after the findings"
      end

      # A checkpoint recorded under an EARLIER claim of the same story.
      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Story, where: s.id == ^ctx.story.id)
          |> Repo.update_all(set: [claim_epoch: @epoch + 1])
        end)

      {:ok, _} = checkpoint(ctx, String.duplicate("f", 40), claim_epoch: @epoch + 1) |> elem_ok()
      {:ok, newest} = latest(ctx)

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(c in Loopctl.Threads.Checkpoint, where: c.id == ^newest.id)
          |> Repo.update_all(set: [claim_epoch: @epoch])
        end)

      assert {:error, :unprocessable_entity, msg} =
               entry(ctx, Map.put(fix, "checkpoint_id", newest.id),
                 as: ctx.agent,
                 claim_epoch: @epoch + 1
               )

      assert msg =~ "current claim"
    end

    test "a key reused for a different entry is refused; the same write replays" do
      ctx = claimed_story()
      attrs = %{"kind" => "message", "idempotency_key" => "round-1", "body" => "first"}
      {:ok, _, :created} = entry(ctx, attrs)

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               entry(ctx, %{attrs | "body" => "second"})

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               entry(ctx, %{attrs | "kind" => "verdict"})
    end

    test "loopctl's key prefix is reserved" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, msg} =
               entry(ctx, %{"kind" => "message", "idempotency_key" => "loopctl:x", "body" => "m"})

      assert msg =~ "loopctl:"
    end

    test "entries are paged" do
      ctx = claimed_story()

      for i <- 1..5,
          do:
            {:ok, _, :created} =
              entry(ctx, %{"kind" => "message", "idempotency_key" => "m#{i}", "body" => "#{i}"})

      {:ok, first} = Threads.get_thread(ctx.tenant_id, ctx.story.id, limit: 2)
      assert Enum.map(first.entries, & &1.body) == ["1", "2"]
      assert first.next_after_seq == 2

      {:ok, last} =
        Threads.get_thread(ctx.tenant_id, ctx.story.id, after_seq: 4, limit: 2)

      assert Enum.map(last.entries, & &1.body) == ["5"]
      assert last.next_after_seq == nil
    end
  end

  defp elem_ok({:ok, cp, :created}), do: {:ok, cp}

  defp set_story(ctx, fields) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in Story, where: s.id == ^ctx.story.id) |> Repo.update_all(set: fields)
      end)
  end

  defp latest(ctx) do
    {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
    {:ok, List.last(thread.checkpoints)}
  end

  describe "authorization by kind" do
    test "a released implementer still cannot judge the checkpoints it recorded" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      set_story(ctx, assigned_agent_id: nil)

      assert {:error, {:conflict, "implementer_cannot_judge", _}} =
               entry(ctx, finding(cp), as: ctx.agent)
    end

    test "a dispatch that recorded a checkpoint cannot judge after its claim is released" do
      ctx = claimed_story()
      root = Ecto.UUID.generate()
      impl = dispatch(ctx.tenant_id, [root])

      {:ok, cp, :created} = checkpoint(ctx, @sha1, actor_lineage: impl.lineage_path)
      set_story(ctx, assigned_agent_id: nil)

      judge = fn key, lineage ->
        Threads.record_entry(ctx.tenant_id, ctx.story.id, finding(cp, key),
          agent_id: ctx.reviewer.id,
          author_principal: "agent:#{ctx.reviewer.id}",
          actor_lineage: lineage
        )
      end

      assert {:error, {:conflict, "implementer_cannot_judge", _}} =
               judge.("child", impl.lineage_path ++ [Ecto.UUID.generate()])

      assert {:ok, _, :created} = judge.("sibling", [root, Ecto.UUID.generate()])
    end

    test "a new claimant cannot judge the thread it now holds" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      set_story(ctx, assigned_agent_id: ctx.reviewer.id)

      assert {:error, {:conflict, "implementer_cannot_judge", _}} = entry(ctx, finding(cp))
    end

    test "a verdict needs a checkpoint to judge" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, msg} =
               entry(ctx, %{"kind" => "verdict", "idempotency_key" => "v", "body" => "ok"})

      assert msg =~ "checkpoint"
    end

    test "a fix without an epoch is a bad request, not an ended claim" do
      ctx = claimed_story()
      {:ok, found_in, :created} = checkpoint(ctx)
      {:ok, f, :created} = entry(ctx, finding(found_in))
      {:ok, cp, :created} = checkpoint(ctx, @sha2)

      fix = %{
        "kind" => "fix",
        "idempotency_key" => "x",
        "body" => "fixed",
        "checkpoint_id" => cp.id,
        "finding_ids" => [f.id]
      }

      assert {:error, :bad_request, _} = entry(ctx, fix, as: ctx.agent)
    end

    test "the implementer cannot judge its own work" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)

      assert {:error, {:conflict, "implementer_cannot_judge", _}} =
               entry(ctx, finding(cp), as: ctx.agent)

      assert {:error, {:conflict, "implementer_cannot_judge", _}} =
               entry(ctx, %{"kind" => "verdict", "idempotency_key" => "v", "body" => "ok"},
                 as: ctx.agent
               )
    end

    test "only the current claimant writes a fix" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      {:ok, f, :created} = entry(ctx, finding(cp))

      fix = %{
        "kind" => "fix",
        "idempotency_key" => "x",
        "body" => "fixed",
        "checkpoint_id" => cp.id,
        "finding_ids" => [f.id]
      }

      assert {:error, :not_claimant} = entry(ctx, fix, claim_epoch: @epoch)

      assert {:error, :stale_claim_epoch} =
               entry(ctx, fix, as: ctx.agent, claim_epoch: @epoch - 1)
    end

    test "a caller on the implementer's dispatch chain cannot judge; a sibling can" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      root = Ecto.UUID.generate()
      impl = dispatch(ctx.tenant_id, [root])

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Story, where: s.id == ^ctx.story.id)
          |> Repo.update_all(set: [implementer_dispatch_id: impl.id])
        end)

      judge = fn key, lineage ->
        Threads.record_entry(ctx.tenant_id, ctx.story.id, finding(cp, key),
          agent_id: ctx.reviewer.id,
          author_principal: "agent:#{ctx.reviewer.id}",
          actor_lineage: lineage
        )
      end

      assert {:error, {:conflict, "implementer_cannot_judge", _}} =
               judge.("child", impl.lineage_path ++ [Ecto.UUID.generate()])

      assert {:ok, _, :created} = judge.("sibling", [root, Ecto.UUID.generate()])
    end

    test "on dispatch-minted work, a key no dispatch minted judges only as a human" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      impl = dispatch(ctx.tenant_id, [Ecto.UUID.generate()])

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Story, where: s.id == ^ctx.story.id)
          |> Repo.update_all(set: [implementer_dispatch_id: impl.id])
        end)

      judge = fn key, agent_id, role ->
        Threads.record_entry(ctx.tenant_id, ctx.story.id, finding(cp, key),
          agent_id: agent_id,
          actor_role: role,
          author_principal: "p:#{key}",
          actor_lineage: []
        )
      end

      assert {:error, :caller_lineage_required} = judge.("legacy", ctx.reviewer.id, :agent)
      assert {:error, :caller_lineage_required} = judge.("orch", nil, :orchestrator)
      assert {:ok, _, :created} = judge.("human", nil, :user)
    end

    test "a human principal may judge" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)

      assert {:ok, _, :created} = entry(ctx, finding(cp), as: nil)
    end
  end

  test "after a completed review round, a finding must say what introduced it" do
    ctx = claimed_story()
    {:ok, cp, :created} = checkpoint(ctx)

    assert {:ok, _, :created} = entry(ctx, finding(cp, "before"))

    {:ok, _, :created} =
      entry(ctx, %{"kind" => "verdict", "idempotency_key" => "r1", "body" => "round 1"})

    assert {:error, :unprocessable_entity, msg} = entry(ctx, finding(cp, "f2"))
    assert msg =~ "introduced_by"

    assert {:error, :unprocessable_entity, _} =
             entry(ctx, Map.put(finding(cp, "f3"), "introduced_by", Ecto.UUID.generate()))

    assert {:ok, _, :created} = entry(ctx, Map.put(finding(cp, "f4"), "introduced_by", "none"))
    assert {:ok, _, :created} = entry(ctx, Map.put(finding(cp, "f5"), "introduced_by", cp.id))

    assert {:ok, upper, :created} =
             entry(ctx, Map.put(finding(cp, "f6"), "introduced_by", String.upcase(cp.id)))

    assert upper.introduced_by == cp.id

    {:ok, later, :created} = checkpoint(ctx, @sha2)

    assert {:error, :unprocessable_entity, msg} =
             entry(ctx, Map.put(finding(cp, "f7"), "introduced_by", later.id))

    assert msg =~ "at or before"
  end

  test "every write appends an audit-chain entry on the story" do
    ctx = claimed_story()
    {:ok, _, :created} = checkpoint(ctx)

    {:ok, _, :created} =
      entry(ctx, %{"kind" => "message", "idempotency_key" => "m", "body" => "hi"})

    actions =
      Repo.all(
        from e in ChainEntry,
          where: e.tenant_id == ^ctx.tenant_id and e.entity_id == ^ctx.story.id,
          order_by: e.chain_position,
          select: e.action
      )

    assert actions == ["thread_checkpoint_recorded", "thread_message_recorded"]
  end

  test "tenant B cannot read or write tenant A's thread" do
    a = claimed_story()
    b = claimed_story()
    {:ok, _, :created} = checkpoint(a)

    assert {:error, :not_found} = Threads.get_thread(b.tenant_id, a.story.id)

    assert {:error, :not_found} =
             Threads.record_entry(
               b.tenant_id,
               a.story.id,
               %{"kind" => "message", "idempotency_key" => "k", "body" => "x"},
               author_principal: "agent:x",
               actor_lineage: []
             )

    assert {:error, :not_found} =
             Threads.record_checkpoint(b.tenant_id, a.story.id,
               agent_id: b.agent.id,
               claim_epoch: @epoch,
               commit_sha: @sha2,
               tree_sha: @tree,
               author_principal: "agent:#{b.agent.id}",
               actor_lineage: []
             )
  end
end
