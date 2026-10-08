defmodule LoopctlWeb.RunnerChannelThreadBrokenChainTest do
  @moduledoc """
  US-45.2: a `checkpoint` or `thread_entry` the tenant's audit chain refuses is answered
  `audit_chain_append_failed` on the wire, and the socket lives. The rest of the events'
  wiring is in `LoopctlWeb.RunnerChannelThreadTest`, async.

  ## Why `async: false`

  The SUBJECT is a broken chain, and the chain's own trigger cannot be driven to that state
  through the application, so the technique is `Loopctl.Delivery.SessionEndReleaseTest`'s: a
  trigger raising exactly what the chain raises, installed on the shared `audit_chain` table
  for THIS tenant only. That is DDL on a table every test appends to; inside an async test's
  sandbox its lock would be held until the test ended, stalling every other test's append
  (`Loopctl.Test.LockGuard` fails such a test at teardown). So it is COMMITTED and dropped at
  exit, which only a module ExUnit runs alone may do.

  The runner is committed too (`fixture(:committed_runner)`, swept at the module boundary),
  for an ordering reason: `fixture(:runner)` enrols through `Loopctl.Runners.enroll_runner/3`,
  which appends to the chain inside the sandbox, and the committed `CREATE TRIGGER` would then
  wait on that row lock for the rest of the test. Everything else stays in the sandbox.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @epoch 3
  @sha1 String.duplicate("a", 40)
  @tree String.duplicate("c", 40)

  defp connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  defp join_payload(machine) do
    %{
      "contract_version" => RunnerContract.version(),
      "machine" => machine,
      "cores" => 16,
      "memory_mb" => 28_000,
      "repos" => ["mkreyman/home_care_billing"],
      "max_sessions" => 2,
      "in_flight" => 0,
      "draining" => false
    }
  end

  # A joined runner holding an ACCEPTED implement dispatch for a story its agent has claimed
  # at `@epoch`, through a custody dispatch as a placement would have minted it.
  setup do
    {raw, runner} = fixture(:committed_runner, %{name: "minis"})
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: @epoch})
    payload = build(:runner_dispatch, %{"story_id" => story.id, "claim_epoch" => @epoch})
    :ok = Runners.dispatch(runner.tenant_id, runner.id, payload)
    assert_push "dispatch", _, @reply_timeout

    ref =
      push(channel, "dispatch_reply", %{
        "dispatch_id" => payload["dispatch_id"],
        "claim_epoch" => @epoch,
        "decision" => "accepted"
      })

    assert_reply ref, :ok, _, @reply_timeout

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

  defp break_chain(tenant_id) do
    name = "test_broken_chain_" <> String.replace(tenant_id, "-", "")

    unboxed(fn ->
      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'audit_chain_hash_violation: injected by test' USING ERRCODE = 'P0001';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE INSERT ON audit_chain FOR EACH ROW
      WHEN (NEW.tenant_id = '#{tenant_id}') EXECUTE FUNCTION #{name}()
      """)
    end)

    on_exit(fn ->
      unboxed(fn ->
        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Loopctl.Repo, fun)

  @tag :capture_log
  test "a write the chain refuses is audit_chain_append_failed, and the socket lives", ctx do
    %{channel: channel, dispatch_id: dispatch_id, runner: runner} = ctx
    break_chain(runner.tenant_id)

    ref = push(channel, "checkpoint", checkpoint_msg(dispatch_id))
    assert_reply ref, :error, %{reason: "audit_chain_append_failed"}, @reply_timeout

    ref = push(channel, "thread_entry", entry_msg(dispatch_id))
    assert_reply ref, :error, %{reason: "audit_chain_append_failed"}, @reply_timeout

    assert Process.alive?(channel.channel_pid)
    assert thread(ctx).entries == []
  end
end
