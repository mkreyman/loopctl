defmodule LoopctlWeb.RunnerChannelThreadTest do
  @moduledoc """
  US-45.2, contract 1.20.0: the `checkpoint` and `thread_entry` events on the runner channel.

  What the coordinator decides — which dispatch may be named, who the write is attributed to,
  the lineage, each refusal's shape — is covered without a socket in
  `Loopctl.Delivery.RunnerThreadsTest` (async). What is here is the WIRING that module cannot
  see: that the channel routes each event, casts it through the contract, meters it with its
  own bucket, answers with the recorded id and `replayed`, and puts each refusal on the wire
  as the contract's published `reason`.

  The socket authenticates its runner through `Loopctl.AdminRepo` while the ledger and the
  thread live on the RLS `Loopctl.Repo`; in test both run on the test's one sandbox connection
  (`Loopctl.AdminRepo.Route`), which the channel process reaches through `$callers`, so every
  row is sandboxed. A write the audit chain refuses needs committed DDL on the shared
  `audit_chain` table, so it is in `LoopctlWeb.RunnerChannelThreadBrokenChainTest`, sync.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 3
  @sha1 String.duplicate("a", 40)
  @sha2 String.duplicate("b", 40)
  @tree String.duplicate("c", 40)

  # A joined runner holding an ACCEPTED implement dispatch for a story its agent has claimed
  # at `@epoch`, through a custody dispatch as a placement would have minted it.
  setup do
    {raw, runner} = fixture(:runner, %{name: "minis"})
    {:ok, socket} = connect_runner_socket(raw)

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, runner_join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: @epoch})
    payload = build(:runner_dispatch, %{"story_id" => story.id, "claim_epoch" => @epoch})
    :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
    assert_push "dispatch", _, reply_timeout()

    ref =
      push(channel, "dispatch_reply", %{
        "dispatch_id" => payload["dispatch_id"],
        "claim_epoch" => @epoch,
        "decision" => "accepted"
      })

    assert_reply ref, :ok, _, reply_timeout()

    custody_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, _} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.insert!(%Dispatch{
          id: custody_id,
          tenant_id: runner.tenant_id,
          role: :agent,
          agent_id: runner.agent_id,
          story_id: story.id,
          lineage_path: [Ecto.UUID.generate(), custody_id],
          expires_at: DateTime.add(now, 3_600),
          created_at: now
        })

        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(
          set: [
            assigned_agent_id: runner.agent_id,
            agent_status: :implementing,
            implementer_dispatch_id: custody_id
          ]
        )
      end)

    %{runner: runner, channel: channel, story: story, dispatch_id: payload["dispatch_id"]}
  end

  defp checkpoint_msg(dispatch_id, attrs \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => dispatch_id,
        "claim_epoch" => @epoch,
        "commit_sha" => @sha1,
        "tree_sha" => @tree
      },
      attrs
    )
  end

  defp entry_msg(dispatch_id, attrs \\ %{}) do
    Map.merge(
      %{
        "dispatch_id" => dispatch_id,
        "claim_epoch" => @epoch,
        "client_seq" => 0,
        "body" => "why this commit"
      },
      attrs
    )
  end

  defp thread(ctx) do
    {:ok, thread} = Threads.get_thread(ctx.runner.tenant_id, ctx.story.id)
    thread
  end

  defp assigns(channel), do: :sys.get_state(channel.channel_pid).assigns

  describe "checkpoint" do
    test "is recorded and answered with its id, seq and replayed; a resend is replayed", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"note" => "first cut"}))
      assert_reply ref, :ok, reply, reply_timeout()

      assert %{seq: 1, replayed: false, checkpoint_id: checkpoint_id} = reply
      assert [%{id: ^checkpoint_id, commit_sha: @sha1}] = thread(ctx).checkpoints

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"note" => "first cut"}))
      assert_reply ref, :ok, %{checkpoint_id: ^checkpoint_id, replayed: true}, reply_timeout()

      assert length(thread(ctx).checkpoints) == 1
    end

    test "a stale epoch is refused with the contract's code and writes nothing", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref =
        push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"claim_epoch" => @epoch + 1}))

      assert_reply ref, :error, %{reason: "claim_epoch_mismatch"}, reply_timeout()
      assert thread(ctx).checkpoints == []
    end

    test "a dispatch that is not an implement is refused wrong_dispatch_kind", ctx do
      %{channel: channel, runner: runner, story: story} = ctx

      triage =
        fixture(:accepted_dispatch, %{
          tenant_id: runner.tenant_id,
          runner: runner,
          story_id: story.id,
          claim_epoch: @epoch,
          kind: "triage"
        })

      ref = push(channel, "checkpoint", checkpoint_msg(triage.dispatch_id))
      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, reply_timeout()

      ref = push(channel, "thread_entry", entry_msg(triage.dispatch_id))
      assert_reply ref, :error, %{reason: "wrong_dispatch_kind"}, reply_timeout()

      assert thread(ctx).entries == []
    end

    test "each refusal the thread gives reaches the wire as the contract's code", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id))
      assert_reply ref, :ok, _, reply_timeout()

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"tree_sha" => @sha2}))
      assert_reply ref, :error, %{reason: "checkpoint_conflict"}, reply_timeout()

      ref =
        push(
          channel,
          "checkpoint",
          checkpoint_msg(dispatch_id, %{
            "commit_sha" => @sha2,
            "note" => "ghp_" <> String.duplicate("A", 36)
          })
        )

      assert_reply ref, :error, %{reason: "secret_blocked"}, reply_timeout()

      other = fixture(:stage_agent, %{tenant_id: runner.tenant_id})

      {:ok, _} =
        Repo.with_tenant(runner.tenant_id, fn ->
          from(s in Story, where: s.id == ^story.id)
          |> Repo.update_all(set: [assigned_agent_id: other.id])
        end)

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"commit_sha" => @sha2}))
      assert_reply ref, :error, %{reason: "not_claimant"}, reply_timeout()

      for reason <- ~w(checkpoint_conflict secret_blocked not_claimant) do
        assert reason in RunnerContract.error_reasons()["checkpoint"]
      end
    end

    test "a malformed message is invalid_payload and spends nothing of the bucket", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id, %{"commit_sha" => "nope"}))

      assert_reply ref, :error, %{reason: "invalid_payload", details: [_ | _]}, reply_timeout()
      assert assigns(channel).checkpoint_bucket == :full
    end

    test "an exhausted bucket refuses with the contract's interval and writes nothing", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      :sys.replace_state(channel.channel_pid, fn socket ->
        future = System.monotonic_time(:millisecond) + 3_600_000
        %{socket | assigns: %{socket.assigns | checkpoint_bucket: {0, future}}}
      end)

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id))

      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: ms}, reply_timeout()
      assert ms == RunnerContract.checkpoint_burst() |> Map.fetch!("refill_interval_ms")
      assert thread(ctx).checkpoints == []
    end

    test "one push against a full bucket leaves exactly capacity - 1, of its OWN bucket", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx
      capacity = RunnerContract.checkpoint_burst() |> Map.fetch!("capacity")

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id))
      assert_reply ref, :ok, _, reply_timeout()

      assert {tokens, _refilled_at} = assigns(channel).checkpoint_bucket
      assert tokens == capacity - 1
      assert assigns(channel).thread_entry_bucket == :full
    end
  end

  describe "thread_entry" do
    test "the same client_seq twice is ONE entry, and the resend says replayed (TC-45.2.3)",
         ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "thread_entry", entry_msg(dispatch_id, %{"client_seq" => 5}))
      assert_reply ref, :ok, %{entry_id: entry_id, seq: 1, replayed: false}, reply_timeout()

      ref = push(channel, "thread_entry", entry_msg(dispatch_id, %{"client_seq" => 5}))
      assert_reply ref, :ok, %{entry_id: ^entry_id, replayed: true}, reply_timeout()

      assert [%{id: ^entry_id, kind: :message, idempotency_key: key}] = thread(ctx).entries
      assert key == "#{dispatch_id}:5"
    end

    test "the same client_seq with other content is idempotency_key_reused", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "thread_entry", entry_msg(dispatch_id))
      assert_reply ref, :ok, _, reply_timeout()

      ref = push(channel, "thread_entry", entry_msg(dispatch_id, %{"body" => "changed my mind"}))
      assert_reply ref, :error, %{reason: "idempotency_key_reused"}, reply_timeout()

      assert "idempotency_key_reused" in RunnerContract.error_reasons()["thread_entry"]
    end

    test "a note may name the checkpoint a checkpoint ack returned", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id))
      assert_reply ref, :ok, %{checkpoint_id: checkpoint_id}, reply_timeout()

      ref =
        push(channel, "thread_entry", entry_msg(dispatch_id, %{"checkpoint_id" => checkpoint_id}))

      assert_reply ref, :ok, %{seq: 2, replayed: false}, reply_timeout()
      assert [_checkpoint_entry, %{checkpoint_id: ^checkpoint_id}] = thread(ctx).entries
    end

    test "a stale epoch is refused with the contract's code and writes nothing", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      ref = push(channel, "thread_entry", entry_msg(dispatch_id, %{"claim_epoch" => @epoch + 1}))

      assert_reply ref, :error, %{reason: "claim_epoch_mismatch"}, reply_timeout()
      assert thread(ctx).entries == []
    end

    test "an exhausted bucket refuses with the contract's interval and writes nothing", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      :sys.replace_state(channel.channel_pid, fn socket ->
        future = System.monotonic_time(:millisecond) + 3_600_000
        %{socket | assigns: %{socket.assigns | thread_entry_bucket: {0, future}}}
      end)

      ref = push(channel, "thread_entry", entry_msg(dispatch_id))

      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: ms}, reply_timeout()
      assert ms == RunnerContract.thread_entry_burst() |> Map.fetch!("refill_interval_ms")
      assert thread(ctx).entries == []
    end

    test "one push against a full bucket leaves exactly capacity - 1, of its OWN bucket", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx
      capacity = RunnerContract.thread_entry_burst() |> Map.fetch!("capacity")

      ref = push(channel, "thread_entry", entry_msg(dispatch_id))
      assert_reply ref, :ok, _, reply_timeout()

      assert {tokens, _refilled_at} = assigns(channel).thread_entry_bucket
      assert tokens == capacity - 1
      assert assigns(channel).checkpoint_bucket == :full
    end
  end
end
