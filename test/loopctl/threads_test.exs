defmodule Loopctl.ThreadsTest do
  @moduledoc "US-45.1: the change-thread ledger."

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
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
    other = fixture(:stage_agent, %{tenant_id: story.tenant_id})
    ctx = %{tenant_id: story.tenant_id, agent: agent, other: other, story: story}
    set_story(ctx, assigned_agent_id: agent.id)
    ctx
  end

  defp dump_ids(row) do
    %{
      row
      | id: Ecto.UUID.dump!(row.id),
        tenant_id: Ecto.UUID.dump!(row.tenant_id),
        story_id: Ecto.UUID.dump!(row.story_id)
    }
  end

  defp set_story(ctx, fields) do
    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in Story, where: s.id == ^ctx.story.id) |> Repo.update_all(set: fields)
      end)
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

  defp entry(ctx, attrs, author \\ "agent:someone") do
    Threads.record_entry(ctx.tenant_id, ctx.story.id, attrs,
      author_principal: author,
      actor_lineage: []
    )
  end

  defp message(key, body \\ "hello"),
    do: %{"kind" => "message", "idempotency_key" => key, "body" => body}

  describe "checkpoints" do
    test "the claimant records one, with a checkpoint entry beside it" do
      ctx = claimed_story()

      assert {:ok, cp, :created} = checkpoint(ctx)
      assert cp.seq == 1 and cp.claim_epoch == @epoch

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      refute thread.checkpoints_truncated
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

      assert {:error, :not_claimant} = checkpoint(ctx, @sha1, agent_id: ctx.other.id)
      assert {:error, :not_claimant} = checkpoint(ctx, @sha1, agent_id: nil)

      # An UNCLAIMED story must not match a key with no agent by nil == nil.
      set_story(ctx, assigned_agent_id: nil)
      assert {:error, :not_claimant} = checkpoint(ctx, @sha1, agent_id: nil)
    end

    test "a claim is live only while claimed, unexpired and not handed to review" do
      ctx = claimed_story()
      future = DateTime.add(DateTime.utc_now(), 600)

      set_story(ctx, claimed_until: DateTime.add(DateTime.utc_now(), -60))
      assert {:error, :claim_not_live} = checkpoint(ctx)

      set_story(ctx, claimed_until: future, review_requested_at: DateTime.utc_now())
      assert {:error, :claim_not_live} = checkpoint(ctx)

      set_story(ctx, review_requested_at: nil, agent_status: :reported_done)
      assert {:error, :claim_not_live} = checkpoint(ctx)

      # A NULL lease is a pre-lease claim: live while claimed, never once it is not.
      set_story(ctx, agent_status: :implementing, claimed_until: nil)
      assert {:ok, _, :created} = checkpoint(ctx)
    end

    test "a resend is the checkpoint already recorded; the next one chains to it" do
      ctx = claimed_story()

      {:ok, first, :created} = checkpoint(ctx)
      assert {:ok, ^first, :existing} = checkpoint(ctx)

      {:ok, second, :created} = checkpoint(ctx, @sha2)
      assert second.seq == 2
      assert second.parent_checkpoint_id == first.id
    end

    test "a new claim resuming at a recorded commit records it again under its own epoch" do
      ctx = claimed_story()
      {:ok, first, :created} = checkpoint(ctx)
      set_story(ctx, claim_epoch: @epoch + 1)

      assert {:ok, again, :created} = checkpoint(ctx, @sha1, claim_epoch: @epoch + 1)
      assert again.claim_epoch == @epoch + 1 and again.seq == first.seq + 1
      # A claim's first checkpoint has no parent: it did not build on the ended claim's.
      assert again.parent_checkpoint_id == nil
    end

    test "a resend for a story that no longer exists is 404, not a replay" do
      ctx = claimed_story()
      {:ok, _, :created} = checkpoint(ctx)

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.query!("DELETE FROM stories WHERE id = $1", [Ecto.UUID.dump!(ctx.story.id)])
        end)

      assert {:error, :not_found} = checkpoint(ctx)
    end

    test "the recorder's resend replays even after its lease lapsed; another agent's is fenced" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      set_story(ctx, claimed_until: DateTime.add(DateTime.utc_now(), -60))

      assert {:ok, ^cp, :existing} = checkpoint(ctx)

      assert {:error, :not_claimant} =
               checkpoint(ctx, @sha1,
                 agent_id: ctx.other.id,
                 author_principal: "agent:#{ctx.other.id}"
               )
    end

    test "the same commit with another tree or note is a conflict" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx, @sha1, note: "why")

      assert {:ok, ^cp, :existing} = checkpoint(ctx, @sha1, note: "why")
      assert {:ok, ^cp, :existing} = checkpoint(ctx)

      assert {:error, {:conflict, "checkpoint_conflict", _}} =
               checkpoint(ctx, @sha1, tree_sha: String.duplicate("9", 40))

      assert {:error, {:conflict, "checkpoint_conflict", _}} =
               checkpoint(ctx, @sha1, note: "another")
    end

    test "malformed shas and notes are refused, and a credential in a note" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, _} = checkpoint(ctx, "HEAD")
      assert {:error, :unprocessable_entity, _} = checkpoint(ctx, @sha1, tree_sha: "abc")

      assert {:error, :unprocessable_entity, msg} =
               checkpoint(ctx, @sha1, tree_sha: String.duplicate("c", 64))

      assert msg =~ "object format"
      assert {:error, :unprocessable_entity, msg} = checkpoint(ctx, @sha1, note: "")
      assert msg =~ "note"
      assert {:error, :unprocessable_entity, msg} = checkpoint(ctx, @sha1, note: "   ")
      assert msg =~ "non-empty"

      too_big = String.duplicate("n", Entry.max_body_bytes() + 1)
      assert {:error, :unprocessable_entity, msg} = checkpoint(ctx, @sha1, note: too_big)
      assert msg =~ "note"

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               checkpoint(ctx, @sha1, note: "ghp_" <> String.duplicate("A", 36))
    end
  end

  describe "entries" do
    test "a retry of the same write is the same entry; another author's key is distinct" do
      ctx = claimed_story()

      {:ok, e1, :created} = entry(ctx, message("k1"))
      assert {:ok, ^e1, :existing} = entry(ctx, message("k1"))
      assert {:ok, e2, :created} = entry(ctx, message("k1"), "agent:other")
      assert e2.id != e1.id and e2.seq == e1.seq + 1
    end

    test "a key reused for a different entry is refused" do
      ctx = claimed_story()
      {:ok, _, :created} = entry(ctx, message("round-1", "first"))

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               entry(ctx, message("round-1", "second"))

      {:ok, cp, :created} = checkpoint(ctx)

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               entry(ctx, Map.put(message("round-1", "first"), "checkpoint_id", cp.id))
    end

    test "a checkpoint_id is canonicalised, so an uppercase resend replays" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      attrs = Map.put(message("c"), "checkpoint_id", String.upcase(cp.id))

      assert {:ok, e, :created} = entry(ctx, attrs)
      assert e.checkpoint_id == cp.id
      assert {:ok, ^e, :existing} = entry(ctx, attrs)
    end

    test "a checkpoint_id must be a UUID naming a checkpoint of this story" do
      ctx = claimed_story()
      other = claimed_story()
      {:ok, other_cp, :created} = checkpoint(other)

      assert {:error, %Ecto.Changeset{} = cs} =
               entry(ctx, Map.put(message("x"), "checkpoint_id", "abc"))

      assert %{checkpoint_id: [_]} = errors_on(cs)

      assert {:error, :unprocessable_entity, _} =
               entry(ctx, Map.put(message("y"), "checkpoint_id", other_cp.id))
    end

    test "judgement kinds and loopctl's own kinds are refused" do
      ctx = claimed_story()

      for kind <- ~w(finding fix verdict review_requested) do
        assert {:error, :unprocessable_entity, msg} =
                 entry(ctx, %{"kind" => kind, "idempotency_key" => kind, "body" => "x"})

        assert msg =~ "review flow"
      end

      for kind <- ~w(checkpoint merge escalation) do
        assert {:error, :unprocessable_entity, msg} =
                 entry(ctx, %{"kind" => kind, "idempotency_key" => kind, "body" => "x"})

        assert msg =~ "written by loopctl"
      end
    end

    test "loopctl's key prefix is reserved" do
      ctx = claimed_story()

      assert {:error, :unprocessable_entity, msg} = entry(ctx, message("loopctl:x"))
      assert msg =~ "loopctl:"
    end

    test "a body over the bound, or carrying a credential, is refused" do
      ctx = claimed_story()
      big = String.duplicate("x", Entry.max_body_bytes() + 1)

      assert {:error, %Ecto.Changeset{} = cs} = entry(ctx, message("big", big))
      assert %{body: [_]} = errors_on(cs)

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               entry(ctx, message("s", "ghp_" <> String.duplicate("A", 36)))

      assert {:ok, %{entries: []}} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
    end

    test "a credential in an idempotency key is refused and reported" do
      ctx = claimed_story()
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "threads-secret-#{inspect(ref)}",
        [:loopctl, :threads, :secret_blocked],
        fn _event, _m, meta, _ -> send(test_pid, {:blocked, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("threads-secret-#{inspect(ref)}") end)
      story_id = ctx.story.id

      assert {:error, :unprocessable_entity, %{code: "secret_blocked"}} =
               entry(ctx, message("ghp_" <> String.duplicate("A", 36)))

      assert_receive {:blocked, %{field: :idempotency_key, story_id: ^story_id}}
    end

    test "a thread returns only its latest page of checkpoints" do
      ctx = claimed_story()
      max = Threads.max_entry_page()
      now = DateTime.utc_now()

      rows =
        for seq <- 1..(max + 1) do
          %{
            id: Ecto.UUID.generate(),
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            seq: seq,
            kind: "checkpoint",
            commit_sha: String.pad_leading(Integer.to_string(seq, 16), 40, "0"),
            tree_sha: @tree,
            claim_epoch: @epoch,
            gate_evidence: %{},
            inserted_at: now,
            updated_at: now
          }
        end

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.insert_all("thread_checkpoints", Enum.map(rows, &dump_ids/1))
        end)

      {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
      assert length(thread.checkpoints) == max
      assert thread.checkpoints_truncated
      assert hd(thread.checkpoints).seq == 2 and List.last(thread.checkpoints).seq == max + 1
    end

    test "entries are paged" do
      ctx = claimed_story()
      for i <- 1..5, do: {:ok, _, :created} = entry(ctx, message("m#{i}", "#{i}"))

      {:ok, first} = Threads.get_thread(ctx.tenant_id, ctx.story.id, limit: 2)
      assert Enum.map(first.entries, & &1.body) == ["1", "2"]
      assert first.next_after_seq == 2

      {:ok, last} = Threads.get_thread(ctx.tenant_id, ctx.story.id, after_seq: 4, limit: 2)
      assert Enum.map(last.entries, & &1.body) == ["5"]
      assert last.next_after_seq == nil
    end
  end

  test "a write that cannot get the story's lock in time is :busy, nothing written" do
    ctx = claimed_story()
    test_pid = self()

    # The holder takes the TRANSACTION-scoped lock the write takes, so the checkin's rollback
    # releases it; a session-level lock would outlive the test on a pooled connection.
    holder =
      spawn(fn ->
        :ok = Sandbox.checkout(Repo)

        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
            Threads.lock_namespace(),
            ctx.story.id
          ])

          send(test_pid, :held)

          receive do
            :release -> :ok
          end
        end)

        Sandbox.checkin(Repo)
      end)

    assert_receive :held, 5_000
    on_exit(fn -> send(holder, :release) end)
    ref = :telemetry_test.attach_event_handlers(self(), [[:loopctl, :threads, :busy]])

    assert {:error, :busy} = entry(ctx, message("blocked"))
    tenant_id = ctx.tenant_id
    assert_receive {[:loopctl, :threads, :busy], ^ref, _, %{tenant_id: ^tenant_id}}
    send(holder, :release)
  end

  test "a new entry fenced on a claim_epoch is refused once the epoch moved; its resend is not" do
    ctx = claimed_story()

    fenced = fn key ->
      Threads.record_entry(ctx.tenant_id, ctx.story.id, message(key),
        author_principal: "agent:runner",
        actor_lineage: [],
        claim_epoch: @epoch
      )
    end

    assert {:ok, _, :created} = fenced.("k1")
    set_story(ctx, claim_epoch: @epoch + 1)

    assert {:error, :stale_claim_epoch} = fenced.("k2")
    # A resend writes nothing, so it is answered from the row: the runner learns it landed.
    assert {:ok, _, :existing} = fenced.("k1")
  end

  test "replay_only answers an entry's resend and refuses a new one" do
    ctx = claimed_story()

    write = fn key, opts ->
      Threads.record_entry(
        ctx.tenant_id,
        ctx.story.id,
        message(key),
        [author_principal: "agent:runner", actor_lineage: []] ++ opts
      )
    end

    assert {:ok, first, :created} = write.("k1", [])
    assert {:ok, ^first, :existing} = write.("k1", replay_only: true)
    assert {:error, :dispatch_not_accepted} = write.("k2", replay_only: true)
  end

  test "every write appends an audit-chain entry on the story" do
    ctx = claimed_story()
    {:ok, _, :created} = checkpoint(ctx)
    {:ok, _, :created} = entry(ctx, message("m"))

    actions =
      Repo.all(
        from e in ChainEntry,
          where: e.tenant_id == ^ctx.tenant_id and e.entity_id == ^ctx.story.id,
          order_by: e.chain_position,
          select: e.action
      )

    assert actions == ["thread_checkpoint_recorded", "thread_message_recorded"]

    [payload | _] =
      Repo.all(
        from e in ChainEntry,
          where: e.tenant_id == ^ctx.tenant_id and e.entity_id == ^ctx.story.id,
          order_by: e.chain_position,
          select: e.payload
      )

    assert %{"commit_sha" => @sha1, "tree_sha" => @tree, "claim_epoch" => @epoch} = payload
  end

  test "tenant B cannot read or write tenant A's thread" do
    a = claimed_story()
    b = claimed_story()
    {:ok, _, :created} = checkpoint(a)

    assert {:error, :not_found} = Threads.get_thread(b.tenant_id, a.story.id)

    assert {:error, :not_found} =
             Threads.record_entry(b.tenant_id, a.story.id, message("k"),
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
