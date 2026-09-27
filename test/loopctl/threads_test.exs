defmodule Loopctl.ThreadsTest do
  @moduledoc "US-45.1: the change-thread ledger."

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Checkpoint
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

    test "claim_checkpoints/2 is the current claim's newest, its earlier ones, and isolation" do
      ctx = claimed_story()
      other = claimed_story()

      assert {:ok, %{latest: nil, earlier_shas: [], earlier_claim_recorded?: false}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)

      {:ok, _first, :created} = checkpoint(ctx, @sha1)
      {:ok, second, :created} = checkpoint(ctx, @sha2)

      assert {:ok, %{latest: latest, earlier_shas: [@sha1], earlier_claim_recorded?: false}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)

      assert latest.id == second.id
      assert {:error, :not_found} = Threads.claim_checkpoints(other.tenant_id, ctx.story.id)
    end

    test "claim_checkpoints/2 reads only the CURRENT claim's claimant checkpoints" do
      ctx = claimed_story()
      {:ok, _recorded, :created} = checkpoint(ctx, @sha1)

      # A later claim: the checkpoint the ended claim recorded is not this claim's work, and
      # is reported as an earlier claim's.
      set_story(ctx, claim_epoch: @epoch + 1)

      assert {:ok, %{latest: nil, earlier_shas: [], earlier_claim_recorded?: true}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)

      # And a checkpoint of another kind under the current claim is not judged either.
      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.insert!(%Loopctl.Threads.Checkpoint{
            tenant_id: ctx.tenant_id,
            story_id: ctx.story.id,
            seq: 2,
            kind: :base_update,
            commit_sha: @sha2,
            tree_sha: @tree,
            claim_epoch: @epoch + 1
          })
        end)

      assert {:ok, %{latest: nil}} = Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)
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

  describe "record_gate_evidence/5 (US-45.6)" do
    test "stores the record under its key and keeps every other key" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)

      assert :ok =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "other", %{
                 "a" => 1
               })

      assert :ok =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", %{
                 "sha" => @sha1
               })

      assert :ok =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", %{
                 "sha" => @sha2
               })

      assert %{"other" => %{"a" => 1}, "ci" => %{"sha" => @sha2}} = stored_evidence(ctx, cp.id)
    end

    # Review round 1, finding 6: a slower evaluation that read earlier never overwrites.
    test "a record read no later than the stored one changes nothing" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      newer = %{"read_at" => "2026-09-27T10:00:01.000000Z", "passed" => ["test"]}
      older = %{"read_at" => "2026-09-27T10:00:00.000000Z", "pending" => ["test"]}

      assert :ok = Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", newer)

      # Round 2, finding 4: the caller is told it did not land.
      assert :superseded =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", older)

      assert %{"ci" => ^newer} = stored_evidence(ctx, cp.id)

      # Round 2, finding 6: the same judgement read later is :ok and writes nothing.
      same_later = %{newer | "read_at" => "2026-09-27T10:00:05.000000Z"}

      assert :ok =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", same_later)

      # #910 round 2, finding 3: the same judgement read later moves the stored read_at, so a
      # slower evaluation that read in between (10:00:03) can no longer pass for the newer one.
      assert %{"ci" => ^same_later} = stored_evidence(ctx, cp.id)

      # The same judgement read EARLIER than what is stored is :ok, never :superseded: the
      # stored record already says the same thing, so an allow resting on it may stand.
      assert :ok = Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", newer)
      assert %{"ci" => ^same_later} = stored_evidence(ctx, cp.id)
      in_between = %{"read_at" => "2026-09-27T10:00:03.000000Z", "pending" => ["test"]}

      assert :superseded =
               Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", in_between)

      newest = %{"read_at" => "2026-09-27T10:00:10.000000Z", "failed" => ["test"]}
      assert :ok = Threads.record_gate_evidence(ctx.tenant_id, ctx.story.id, cp.id, "ci", newest)
      assert %{"ci" => ^newest} = stored_evidence(ctx, cp.id)
    end

    test "another story's checkpoint, or another tenant's, is not_found and untouched" do
      ctx = claimed_story()
      {:ok, cp, :created} = checkpoint(ctx)
      other = claimed_story()

      assert {:error, :not_found} =
               Threads.record_gate_evidence(ctx.tenant_id, other.story.id, cp.id, "ci", %{
                 "x" => 1
               })

      assert {:error, :not_found} =
               Threads.record_gate_evidence(other.tenant_id, ctx.story.id, cp.id, "ci", %{
                 "x" => 1
               })

      assert stored_evidence(ctx, cp.id) == %{}
    end
  end

  defp stored_evidence(ctx, checkpoint_id) do
    {:ok, evidence} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.one!(
          from c in Loopctl.Threads.Checkpoint,
            where: c.id == ^checkpoint_id,
            select: c.gate_evidence
        )
      end)

    evidence
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

  describe "control-plane writes (US-45.5)" do
    @merge String.duplicate("d", 40)
    @merge_tree String.duplicate("9", 40)

    # A thread story at `ci` whose recorded allow names checkpoint `@sha1`, as the merge gate
    # leaves it: the row's `merge_gate_allowed_sha` and the `effect_recorded` event naming the
    # checkpoint (`Stages.last_allow_query/2`).
    defp allowed_at_ci do
      ctx = claimed_story()

      cp =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          seq: 1,
          commit_sha: @sha1,
          tree_sha: @tree,
          claim_epoch: @epoch
        })

      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        stage: :ci,
        claim_epoch: @epoch,
        head_sha: @sha1
      })

      {:ok, _} =
        Stages.record_effect(ctx.tenant_id, ctx.story.id, :merge_gate_allowed_sha, @sha1,
          claim_epoch: @epoch,
          event_data: %{"checkpoint_id" => cp.id, "checkpoint_sha" => @sha1, "base_sha" => @sha2}
        )

      Map.put(ctx, :checkpoint, cp)
    end

    defp base_update(ctx, parent_id \\ nil) do
      Threads.record_base_update(ctx.tenant_id, ctx.story.id, parent_id || ctx.checkpoint.id,
        commit_sha: @merge,
        tree_sha: @merge_tree
      )
    end

    test "TC-45.5.8 a base update is recorded and the story stays at ci on it, review and custody kept" do
      ctx = allowed_at_ci()
      set_story(ctx, verified_status: :verified)

      assert {:ok, bu, :created} = base_update(ctx)
      assert bu.kind == :base_update and bu.parent_checkpoint_id == ctx.checkpoint.id
      assert bu.claim_epoch == @epoch and is_nil(bu.dispatch_id)

      row = Stages.get(ctx.tenant_id, ctx.story.id)
      assert row.stage == :ci
      assert row.head_sha == @merge
      assert is_nil(row.merge_gate_allowed_sha)
      assert row.attempts == %{"base_updated" => 1}

      {:ok, story} = Repo.with_tenant(ctx.tenant_id, fn -> Repo.get!(Story, ctx.story.id) end)
      assert story.verified_status == :verified
      assert story.assigned_agent_id == ctx.agent.id

      # The entry is the executor's, and the chain names the base update and its parent.
      {:ok, entry} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.one!(from e in Entry, where: e.checkpoint_id == ^bu.id)
        end)

      assert entry.author_principal == Threads.merge_executor_principal()

      {:ok, [chained]} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.all(
            from c in ChainEntry,
              where: c.entity_id == ^ctx.story.id and c.action == "thread_checkpoint_recorded"
          )
        end)

      assert chained.payload["checkpoint_kind"] == "base_update"
      assert chained.payload["parent_checkpoint_id"] == ctx.checkpoint.id
    end

    test "the same base update again is the one recorded; another tree is a conflict" do
      ctx = allowed_at_ci()
      {:ok, bu, :created} = base_update(ctx)

      assert {:ok, ^bu, :existing} = base_update(ctx)

      assert {:error, {:conflict, "checkpoint_conflict", _}} =
               Threads.record_base_update(ctx.tenant_id, ctx.story.id, ctx.checkpoint.id,
                 commit_sha: @merge,
                 tree_sha: String.duplicate("8", 40)
               )
    end

    test "only for the checkpoint the allow names, at ci, under the current claim; nothing written otherwise" do
      ctx = allowed_at_ci()

      other =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          seq: 2,
          commit_sha: @sha2,
          claim_epoch: @epoch
        })

      assert {:error, :allow_not_for_parent} = base_update(ctx, other.id)

      set_story(ctx, claim_epoch: @epoch + 1)
      assert {:error, :stale_claim_epoch} = base_update(ctx)
      set_story(ctx, claim_epoch: @epoch)

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Loopctl.Delivery.StoryStage, where: s.story_id == ^ctx.story.id)
          |> Repo.update_all(set: [stage: :implementing])
        end)

      assert {:error, :stale_stage} = base_update(ctx)

      {:ok, kinds} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          Repo.all(from c in Checkpoint, where: c.story_id == ^ctx.story.id, select: c.kind)
        end)

      assert Enum.sort(kinds) == [:checkpoint, :checkpoint]
    end

    test "a parent an ENDED claim recorded is refused, even at the commit the allow names" do
      ctx = allowed_at_ci()

      # The current claim resumed at the same commit and the stage row followed it: the allow
      # names that sha, but the ended claim's checkpoint is not the one the gate judged.
      set_story(ctx, claim_epoch: @epoch + 1)

      {:ok, _} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Loopctl.Delivery.StoryStage, where: s.story_id == ^ctx.story.id)
          |> Repo.update_all(set: [claim_epoch: @epoch + 1])
        end)

      assert {:error, :stale_claim_epoch} = base_update(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story.id).head_sha == @sha1
    end

    test "TC-45.5.10 claim_checkpoints judges a base update reaching the allowed checkpoint, and no other" do
      ctx = allowed_at_ci()

      # An unrelated base update — its parent is a checkpoint the gate never allowed — is
      # invisible, and the allowed checkpoint stays the judged head.
      other =
        fixture(:thread_checkpoint, %{
          tenant_id: ctx.tenant_id,
          story_id: ctx.story.id,
          seq: 2,
          commit_sha: @sha2,
          claim_epoch: @epoch - 1
        })

      fixture(:thread_checkpoint, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        seq: 3,
        kind: :base_update,
        commit_sha: String.duplicate("7", 40),
        parent_checkpoint_id: other.id,
        claim_epoch: @epoch
      })

      assert {:ok, %{latest: %{id: id}, earlier_shas: []}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)

      assert id == ctx.checkpoint.id

      # The executor's base update of the allowed checkpoint is the judged head.
      {:ok, bu, :created} = base_update(ctx)

      assert {:ok, %{latest: %{id: judged}, earlier_shas: [@sha1]}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)

      assert judged == bu.id

      # A second base move merges into the FIRST base update: its parents still reach the
      # checkpoint the gate last allowed, through it.
      fixture(:thread_checkpoint, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story.id,
        seq: 5,
        kind: :base_update,
        commit_sha: String.duplicate("6", 40),
        parent_checkpoint_id: bu.id,
        claim_epoch: @epoch
      })

      assert {:ok, %{latest: %{commit_sha: "6666666666666666666666666666666666666666"}}} =
               Threads.claim_checkpoints(ctx.tenant_id, ctx.story.id)
    end

    test "record_merge_commit/5 is a compare-and-set on the recorded commit" do
      ctx = allowed_at_ci()
      cp = ctx.checkpoint

      assert :ok = Threads.record_merge_commit(ctx.tenant_id, ctx.story.id, cp.id, nil, @merge)
      assert :ok = Threads.record_merge_commit(ctx.tenant_id, ctx.story.id, cp.id, nil, @merge)

      assert {:error, {:merge_commit_moved, @merge}} =
               Threads.record_merge_commit(ctx.tenant_id, ctx.story.id, cp.id, nil, @sha2)

      assert :ok = Threads.record_merge_commit(ctx.tenant_id, ctx.story.id, cp.id, @merge, @sha2)

      {:ok, stored} =
        Repo.with_tenant(ctx.tenant_id, fn -> Repo.get!(Checkpoint, cp.id).merge_commit_sha end)

      assert stored == @sha2
    end

    test "tenant B can neither record a base update nor a merge commit on tenant A's thread" do
      a = allowed_at_ci()
      b = claimed_story()

      assert {:error, :not_found} =
               Threads.record_base_update(b.tenant_id, a.story.id, a.checkpoint.id,
                 commit_sha: @merge,
                 tree_sha: @merge_tree
               )

      assert {:error, :not_found} =
               Threads.record_merge_commit(b.tenant_id, a.story.id, a.checkpoint.id, nil, @merge)

      {:ok, cp} = Repo.with_tenant(a.tenant_id, fn -> Repo.get!(Checkpoint, a.checkpoint.id) end)
      assert is_nil(cp.merge_commit_sha)
      assert Stages.get(a.tenant_id, a.story.id).head_sha == @sha1
    end
  end
end
