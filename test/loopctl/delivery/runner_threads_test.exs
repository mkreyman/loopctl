defmodule Loopctl.Delivery.RunnerThreadsTest do
  @moduledoc """
  US-45.2: a runner's `checkpoint` and `thread_entry` messages, applied to the story's change
  thread by `Loopctl.Delivery.RunnerThreads`.

  The thread's own rules (the fence, the replay, the scrub) are `Loopctl.ThreadsTest`'s. What
  is here is what the coordinator adds: which dispatch the message may name, WHO the write is
  attributed to — the runner's agent, under the CUSTODY dispatch's lineage rather than the
  runner key's empty one — and how each refusal comes back. The channel wiring is
  `LoopctlWeb.RunnerChannelThreadTest`'s.

  Everything lives on the RLS `Loopctl.Repo` sandbox connection, so this stays `async: true`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Delivery.RunnerThreads
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.ActorLabel

  setup :verify_on_exit!

  @epoch 3
  @sha1 String.duplicate("a", 40)
  @sha2 String.duplicate("b", 40)
  @tree String.duplicate("c", 40)
  @tree2 String.duplicate("d", 40)

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  # A story claimed by the runner's agent at `@epoch` through a placement's custody dispatch,
  # with an accepted dispatch of `kind` on the runner's ledger.
  defp session(opts \\ []) do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: @epoch,
        kind: Keyword.get(opts, :kind, "implement")
      })

    custody = custody_dispatch(story, runner)
    set_story(story, assigned_agent_id: runner.agent_id, implementer_dispatch_id: custody.id)

    %{story: story, runner: runner, record: record, custody: custody}
  end

  # The session dispatch a placement mints (`Placement.mint_session_dispatch/5`): a child of
  # the placing caller's dispatch, so its lineage is two long and ends in its own id.
  defp custody_dispatch(story, runner) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    as_tenant(story.tenant_id, fn ->
      Repo.insert!(%Dispatch{
        id: id,
        tenant_id: story.tenant_id,
        role: :agent,
        agent_id: runner.agent_id,
        story_id: story.id,
        lineage_path: [Ecto.UUID.generate(), id],
        expires_at: DateTime.add(now, 3_600),
        created_at: now
      })
    end)
  end

  defp set_story(story, fields) do
    as_tenant(story.tenant_id, fn ->
      from(s in Story, where: s.id == ^story.id) |> Repo.update_all(set: fields)
    end)
  end

  defp set_status(ctx, status) do
    as_tenant(ctx.story.tenant_id, fn ->
      from(r in DispatchRecord, where: r.id == ^ctx.record.id)
      |> Repo.update_all(set: [status: status])
    end)
  end

  defp checkpoint_message(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        commit_sha: @sha1,
        tree_sha: @tree
      },
      attrs
    )
  end

  defp entry_message(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        client_seq: 0,
        body: "the reason for the commit"
      },
      attrs
    )
  end

  defp checkpoint(ctx, attrs \\ %{}),
    do:
      RunnerThreads.record_checkpoint(
        ctx.story.tenant_id,
        ctx.runner,
        checkpoint_message(ctx, attrs)
      )

  defp entry(ctx, attrs \\ %{}),
    do: RunnerThreads.record_entry(ctx.story.tenant_id, ctx.runner, entry_message(ctx, attrs))

  defp thread(ctx) do
    {:ok, thread} = Threads.get_thread(ctx.story.tenant_id, ctx.story.id)
    thread
  end

  defp chain_lineages(ctx) do
    Repo.all(
      from e in ChainEntry,
        where: e.tenant_id == ^ctx.story.tenant_id and e.entity_id == ^ctx.story.id,
        order_by: e.chain_position,
        select: e.actor_lineage
    )
  end

  describe "record_checkpoint/3" do
    test "records the commit as the runner's agent, under the CUSTODY dispatch's lineage" do
      ctx = session()

      assert {:ok, %{checkpoint: cp, replayed?: false}} = checkpoint(ctx, %{note: "first cut"})
      assert cp.commit_sha == @sha1 and cp.tree_sha == @tree and cp.claim_epoch == @epoch

      # The dispatch the claim recorded, not the runner key's empty lineage: the checkpoint,
      # its entry and its chain entry all name the dispatch that did the work.
      assert cp.dispatch_id == ctx.custody.id

      assert [%{kind: :checkpoint, body: "first cut"} = cp_entry] = thread(ctx).entries
      assert cp_entry.author_principal == "agent:" <> ctx.runner.agent_id
      assert cp_entry.dispatch_id == ctx.custody.id

      assert chain_lineages(ctx) == [ctx.custody.lineage_path]
    end

    test "the principal is ActorLabel's spelling of a key carrying the runner's agent" do
      # The HTTP surface attributes a write by `ActorLabel.of/1`; a checkpoint the runner
      # reported over the socket must carry the SAME principal, or a resend over the other
      # path is a stranger to `Loopctl.Threads`' replay check.
      %{runner: runner} = session()

      assert RunnerThreads.principal(runner) ==
               ActorLabel.of(%{agent_id: runner.agent_id, id: runner.api_key_id})
    end

    test "a resend is the checkpoint already recorded, and says so" do
      ctx = session()

      {:ok, %{checkpoint: first, replayed?: false}} = checkpoint(ctx)
      assert {:ok, %{checkpoint: again, replayed?: true}} = checkpoint(ctx)
      assert again.id == first.id

      assert length(thread(ctx).checkpoints) == 1
    end

    test "the same commit with another tree is checkpoint_conflict" do
      ctx = session()
      {:ok, _} = checkpoint(ctx)

      assert {:error, :checkpoint_conflict} = checkpoint(ctx, %{tree_sha: @tree2})
    end

    test "an epoch that is not the dispatch's is stale_claim_epoch, and writes nothing" do
      ctx = session()

      # The story's CURRENT claim is the runner's agent at the epoch the message names, so the
      # thread's own fence would pass it. The dispatch the message names ran under the epoch
      # before, and a checkpoint must not be recorded under a claim its dispatch did not hold.
      set_story(ctx.story, claim_epoch: @epoch + 1)

      assert {:error, :stale_claim_epoch} = checkpoint(ctx, %{claim_epoch: @epoch + 1})
      assert thread(ctx).checkpoints == []
    end

    test "a dispatch whose story is gone is unknown_dispatch, for both messages" do
      ctx = session()
      set_story(ctx.story, implementer_dispatch_id: nil)

      as_tenant(ctx.story.tenant_id, fn ->
        Repo.delete!(ctx.custody)
        Repo.delete_all(from s in Story, where: s.id == ^ctx.story.id)
      end)

      assert {:error, :unknown_dispatch} = checkpoint(ctx)
      assert {:error, :unknown_dispatch} = entry(ctx)
    end

    test "a triage dispatch is unknown_dispatch: a triage session has no claim to report on" do
      ctx = session(kind: "triage")

      assert {:error, :unknown_dispatch} = checkpoint(ctx)
      assert {:error, :unknown_dispatch} = entry(ctx)
      assert thread(ctx).entries == []
    end

    test "a story claimed by another agent is not_claimant" do
      ctx = session()
      other = fixture(:stage_agent, %{tenant_id: ctx.story.tenant_id})
      set_story(ctx.story, assigned_agent_id: other.id)

      assert {:error, :not_claimant} = checkpoint(ctx)
    end

    test "a claim whose lease ran out is claim_not_live" do
      ctx = session()
      set_story(ctx.story, claimed_until: DateTime.add(DateTime.utc_now(), -60))

      assert {:error, :claim_not_live} = checkpoint(ctx)
    end

    test "after the claim moved on, a new commit is refused and the recorder's resend is not" do
      ctx = session()
      {:ok, %{checkpoint: recorded}} = checkpoint(ctx)

      # A reclaim bumped the epoch; the runner's ledger row still names the old one.
      set_story(ctx.story, claim_epoch: @epoch + 1)

      assert {:error, :stale_claim_epoch} = checkpoint(ctx, %{commit_sha: @sha2})

      # A lost ack re-sent after the claim ended must not read as "never recorded".
      assert {:ok, %{checkpoint: again, replayed?: true}} = checkpoint(ctx)
      assert again.id == recorded.id
    end

    test "once the ledger row is superseded, the resend is answered and nothing new is written" do
      ctx = session()
      {:ok, %{checkpoint: recorded}} = checkpoint(ctx)

      # The release bumped the epoch, and a reply or trace then marked the row superseded.
      set_story(ctx.story, claim_epoch: @epoch + 1)
      set_status(ctx, "superseded")

      assert {:ok, %{checkpoint: again, replayed?: true}} = checkpoint(ctx)
      assert again.id == recorded.id

      assert {:error, :dispatch_not_accepted} =
               checkpoint(ctx, %{commit_sha: @sha2, tree_sha: @tree2})

      assert {:error, :dispatch_not_accepted} = entry(ctx)
      assert length(thread(ctx).checkpoints) == 1
    end

    test "a note's resend after the claim moved and the row went superseded is answered" do
      ctx = session()
      {:ok, %{entry: recorded}} = entry(ctx)

      set_story(ctx.story, claim_epoch: @epoch + 1)
      assert {:ok, %{entry: again, replayed?: true}} = entry(ctx)
      assert again.id == recorded.id

      set_status(ctx, "superseded")
      assert {:ok, %{entry: ^again, replayed?: true}} = entry(ctx)
      assert {:error, :dispatch_not_accepted} = entry(ctx, %{client_seq: 1})
    end

    test "a row that is not accepted records no checkpoint, though the claim is still live" do
      ctx = session()
      set_status(ctx, "superseded")

      assert {:error, :dispatch_not_accepted} = checkpoint(ctx)
      assert thread(ctx).checkpoints == []
    end

    test "a claim no placement made carries no lineage, because it genuinely has none" do
      ctx = session()
      set_story(ctx.story, implementer_dispatch_id: nil)

      assert {:ok, %{checkpoint: cp}} = checkpoint(ctx)
      assert cp.dispatch_id == nil
      assert chain_lineages(ctx) == [[]]
    end

    test "a credential in the note is secret_blocked, and a blank one is invalid" do
      ctx = session()

      assert {:error, :secret_blocked} =
               checkpoint(ctx, %{note: "token ghp_" <> String.duplicate("A", 36)})

      assert {:error, {:invalid, [detail]}} = checkpoint(ctx, %{note: "   "})
      assert detail =~ "note"

      assert {:error, {:invalid, [format]}} =
               checkpoint(ctx, %{tree_sha: String.duplicate("e", 64)})

      assert format =~ "object format"
      assert thread(ctx).checkpoints == []
    end
  end

  describe "record_entry/3" do
    test "records a message keyed dispatch_id:client_seq, under the custody lineage" do
      ctx = session()

      assert {:ok, %{entry: entry, replayed?: false}} = entry(ctx, %{client_seq: 4})

      assert entry.kind == :message
      assert entry.idempotency_key == "#{ctx.record.dispatch_id}:4"
      assert entry.author_principal == "agent:" <> ctx.runner.agent_id
      assert entry.dispatch_id == ctx.custody.id
      assert chain_lineages(ctx) == [ctx.custody.lineage_path]
    end

    test "the same client_seq and content is a replay; other content is idempotency_key_reused" do
      ctx = session()

      {:ok, %{entry: first, replayed?: false}} = entry(ctx)
      assert {:ok, %{entry: again, replayed?: true}} = entry(ctx)
      assert again.id == first.id

      assert {:error, :idempotency_key_reused} = entry(ctx, %{body: "something else"})

      # A new number is a new note.
      assert {:ok, %{replayed?: false}} = entry(ctx, %{client_seq: 1})
      assert length(thread(ctx).entries) == 2
    end

    test "a note may name a checkpoint of its story, and no other" do
      ctx = session()
      {:ok, %{checkpoint: cp}} = checkpoint(ctx)

      assert {:ok, %{entry: entry}} = entry(ctx, %{checkpoint_id: cp.id})
      assert entry.checkpoint_id == cp.id

      assert {:error, {:invalid, [detail]}} =
               entry(ctx, %{client_seq: 1, checkpoint_id: Ecto.UUID.generate()})

      assert detail =~ "checkpoint_id"
    end

    test "after the claim moved on, a note is stale_claim_epoch and writes nothing" do
      ctx = session()
      set_story(ctx.story, claim_epoch: @epoch + 1)

      assert {:error, :stale_claim_epoch} = entry(ctx)
      assert thread(ctx).entries == []
    end

    test "an epoch that is not the dispatch's is stale_claim_epoch, though it is the story's" do
      ctx = session()
      set_story(ctx.story, claim_epoch: @epoch + 1)

      assert {:error, :stale_claim_epoch} = entry(ctx, %{claim_epoch: @epoch + 1})
      assert thread(ctx).entries == []
    end

    test "a blank body is invalid with the changeset's words, a credential is secret_blocked" do
      ctx = session()

      assert {:error, {:invalid, ["body can't be blank"]}} = entry(ctx, %{body: "   "})

      assert {:error, :secret_blocked} =
               entry(ctx, %{body: "ghp_" <> String.duplicate("A", 36)})

      assert thread(ctx).entries == []
    end
  end

  describe "database failures" do
    @describetag :capture_log

    setup do
      %{message: %{dispatch_id: Ecto.UUID.generate()}}
    end

    test "a deadlock, a lock timeout and a pool timeout are busy, not a raise", %{message: m} do
      for error <- [
            %Postgrex.Error{postgres: pg_error(:deadlock_detected, "40P01")},
            %Postgrex.Error{postgres: pg_error(:lock_not_available, "55P03")},
            DBConnection.ConnectionError.exception("checkout timed out")
          ] do
        assert {:error, :busy} =
                 RunnerThreads.answering_database(Ecto.UUID.generate(), m, "t", fn ->
                   raise error
                 end)
      end
    end

    test "a hash-chain violation is audit_chain_append_failed; anything else raises",
         %{message: m} do
      violation = %Postgrex.Error{
        postgres: %{pg_code: "P0001", message: "audit_chain_hash_violation: broken"}
      }

      assert {:error, :audit_chain_append_failed} =
               RunnerThreads.answering_database(Ecto.UUID.generate(), m, "t", fn ->
                 raise violation
               end)

      assert_raise Postgrex.Error, fn ->
        RunnerThreads.answering_database(Ecto.UUID.generate(), m, "t", fn ->
          raise %Postgrex.Error{postgres: pg_error(:unique_violation, "23505")}
        end)
      end
    end
  end

  defp pg_error(code, pg_code),
    do: %{code: code, pg_code: pg_code, severity: "ERROR", message: Atom.to_string(code)}

  describe "tenant isolation" do
    test "a runner cannot write to the thread of another tenant's dispatch" do
      a = session()
      b = session()

      # b's runner against a's tenant, and a's runner reaching into b's: the ledger's
      # ownership predicate is (tenant, runner), so both are a dispatch that does not exist.
      assert {:error, :unknown_dispatch} =
               RunnerThreads.record_checkpoint(a.story.tenant_id, b.runner, checkpoint_message(a))

      assert {:error, :unknown_dispatch} =
               RunnerThreads.record_entry(b.story.tenant_id, a.runner, entry_message(a))

      assert thread(a).entries == []
      assert thread(b).entries == []
    end
  end
end
