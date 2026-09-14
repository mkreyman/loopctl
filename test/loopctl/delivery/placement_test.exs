defmodule Loopctl.Delivery.PlacementTest do
  @moduledoc """
  Issue #803: the dispatch claims the story it is sent for.

  `async: false`, and COMMITTED rather than sandboxed, for a reason that is a fact about the
  code under test rather than a convenience. A placement spans BOTH repos — the claim is an
  `AdminRepo` transaction (`Loopctl.Progress.claim_story/3`) and the `queued -> claimed`
  transition is a `Loopctl.Repo` one, because `Loopctl.AuditChain.append_in_tenant_transaction/2`
  raises outside a `Repo` transaction and that transition is chained. The two sandbox
  connections cannot see each other's uncommitted work, and worse, the claim's UPDATE holds
  the story row, so the transition's `FOR SHARE` would sit on it until its `lock_timeout`.
  Everything the placement touches is therefore committed, and
  `sweep_committed_runner_tenants/0` removes it — chain entries included.
  """

  use LoopctlWeb.ChannelCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Progress
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.WorkBreakdown.Stories
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000

  setup do
    {raw, runner} = fixture(:committed_runner, %{name: "minis"})

    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(raw))

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> runner.id, join_payload("minis"))

    _ = :sys.get_state(channel.channel_pid)

    # `fixture(:committed_story)` checks out its OWN unboxed connection, so it is called
    # OUTSIDE `unboxed/1`: nesting two `unboxed_run`s on `Loopctl.Repo` checks the connection
    # back in at the inner block's end, and the rest of the setup would then run on the SHARED
    # SANDBOX connection — whose transaction never commits, so the `FOR SHARE` a stage
    # transition takes would hold the story row for the whole test and the claim would sit on
    # it until its lock timeout.
    story = fixture(:committed_story, %{tenant_id: runner.tenant_id})
    story = unboxed(fn -> contract_and_queue(runner.tenant_id, story) end)

    %{runner: runner, channel: channel, story: story}
  end

  describe "place/4" do
    test "claims the story, enters `claimed` and pushes the dispatch", ctx do
      %{runner: runner, story: story} = ctx
      payload = dispatch_payload(story)

      assert {:ok, placed} = place(runner, payload)
      assert_push "dispatch", pushed, @reply_timeout

      assert pushed.dispatch_id == payload["dispatch_id"]
      assert pushed.claim_epoch == placed.claim_epoch

      claimed = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert claimed.agent_status == :assigned
      assert claimed.assigned_agent_id == runner.agent_id
      assert claimed.implementer_dispatch_id == placed.implementer_dispatch_id
      assert claimed.claim_epoch == placed.claim_epoch
      assert claimed.claim_epoch > story.claim_epoch

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :claimed
      assert row.runner_id == runner.id
      assert row.claim_epoch == placed.claim_epoch
    end

    test "the claim's chain entry is attributed to the dispatch it minted", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(runner, dispatch_payload(story))
      assert_push "dispatch", _pushed, @reply_timeout

      session = unboxed(fn -> AdminRepo.get!(Dispatch, placed.implementer_dispatch_id) end)
      entry = unboxed(fn -> claimed_entry(runner.tenant_id, story.id) end)

      # Not `[]`, and not anything this path invented: the lineage of a dispatch row that was
      # really minted, rooted where the CALLER's own lineage put it.
      assert entry.actor_lineage == session.lineage_path
      assert session.lineage_path != []
      assert session.agent_id == runner.agent_id
      assert session.story_id == story.id
      assert session.role == :agent
    end

    test "the session dispatch lands inside the caller's own subtree", ctx do
      %{runner: runner, story: story} = ctx
      parent = unboxed(fn -> operator_dispatch(runner.tenant_id) end)

      assert {:ok, placed} =
               place(runner, dispatch_payload(story),
                 caller_lineage: parent.lineage_path,
                 caller_role: :orchestrator
               )

      assert_push "dispatch", _pushed, @reply_timeout

      session = unboxed(fn -> AdminRepo.get!(Dispatch, placed.implementer_dispatch_id) end)
      assert session.parent_dispatch_id == List.last(parent.lineage_path)
      assert List.starts_with?(session.lineage_path, parent.lineage_path)
    end

    test "an unlineaged caller below :user may not start a tree, and claims nothing", ctx do
      %{runner: runner, story: story} = ctx

      assert {:error, :root_dispatch_forbidden} =
               place(runner, dispatch_payload(story),
                 caller_lineage: [],
                 caller_role: :orchestrator
               )

      refute_push "dispatch", _pushed, 200

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :queued
    end

    test "a re-sent dispatch_id claims nothing a second time, and releases nothing", ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      payload = dispatch_payload(story)

      assert {:ok, first} = place(runner, payload)
      assert_push "dispatch", _pushed, @reply_timeout

      # The runner goes away between the two placements, so the RETRY refuses at the push.
      # That is the interesting shape: the retry resumed from the ledger, so it must neither
      # claim again NOR release the claim the first placement made — a session may be running
      # under it. (That a re-send reaches the socket again is `Runners.dispatch/3`'s own
      # behaviour and is covered in `LoopctlWeb.RunnerChannelDispatchTest`; it cannot be
      # asserted here, because the channel marked the ledger row `pushed` inside the shared
      # SANDBOX transaction and that row lock is held for the rest of the test.)
      disconnect(channel, runner)

      assert {:error, :runner_not_connected} = place(runner, payload)

      after_retry = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert after_retry.claim_epoch == first.claim_epoch
      assert after_retry.agent_status == :assigned
      assert after_retry.implementer_dispatch_id == first.implementer_dispatch_id
      assert unboxed(fn -> session_dispatch_count(runner.tenant_id, story.id) end) == 1
      assert unboxed(fn -> Stages.get(runner.tenant_id, story.id) end).stage == :claimed

      record =
        unboxed(fn -> DispatchLedger.get_record(runner.tenant_id, payload["dispatch_id"]) end)

      assert record.claim_epoch == first.claim_epoch
    end

    test "a refused push releases the claim it made", ctx do
      %{runner: runner, story: story, channel: channel} = ctx

      # The runner leaves before the dispatch is placed, so `Runners.dispatch/3` refuses
      # `:runner_not_connected` AFTER the claim has committed — the window this compensates.
      disconnect(channel, runner)

      assert {:error, :runner_not_connected} = place(runner, dispatch_payload(story))

      released = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert released.agent_status == :pending
      assert is_nil(released.assigned_agent_id)

      row = unboxed(fn -> Stages.get(runner.tenant_id, story.id) end)
      assert row.stage == :queued
      assert is_nil(row.runner_id)
      assert row.claim_epoch == released.claim_epoch
    end

    test "a payload with no usable dispatch_id is refused before anything is claimed", ctx do
      %{runner: runner, story: story} = ctx
      payload = Map.put(dispatch_payload(story), "dispatch_id", "not-a-uuid")

      assert {:error, {:invalid, ["dispatch_id: must be a UUID"]}} = place(runner, payload)

      untouched = unboxed(fn -> reload(runner.tenant_id, story.id) end)
      assert untouched.agent_status == :contracted
      assert untouched.claim_epoch == story.claim_epoch
    end
  end

  describe "the minted credential does not reach the session" do
    test "the dispatch payload has no field that could carry a key" do
      # The premise of the moduledoc's "the credential ... does NOT reach the session"
      # section, asserted rather than asserted-in-prose: a session therefore still
      # authenticates as the runner's enrollment key. Adding such a field is what makes a
      # runner session a custody principal, and this is what goes red when someone does.
      refute Enum.any?(
               RunnerContract.RunnerDispatch.schema().properties,
               fn {name, _schema} -> String.contains?(Atom.to_string(name), "key") end
             )
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  defp place(runner, payload, opts \\ []) do
    opts = Keyword.merge([caller_lineage: [], caller_role: :user], opts)
    unboxed(fn -> Placement.place(runner.tenant_id, runner.id, payload, opts) end)
  end

  # BOTH repos on real connections. A placement writes through each of them and the sandbox
  # gives them separate, mutually invisible transactions — see the moduledoc.
  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  # A story contracted and standing at `queued`, which is what a placement takes.
  defp contract_and_queue(tenant_id, story) do
    {:ok, story} =
      Progress.contract_story(tenant_id, story.id, %{},
        actor_label: "test",
        skip_contract_check: true
      )

    {:ok, _row} = Stages.open(tenant_id, story.id, actor_label: "test")

    epoch = story.claim_epoch
    {:ok, _} = Stages.advance(tenant_id, story.id, {:detected, :triaged}, claim_epoch: epoch)
    {:ok, _} = Stages.advance(tenant_id, story.id, {:triaged, :queued}, claim_epoch: epoch)

    story
  end

  defp operator_dispatch(tenant_id) do
    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant_id, %{role: :orchestrator}, actor_lineage: [])

    dispatch
  end

  defp dispatch_payload(story) do
    build(:runner_dispatch, %{
      "story_id" => story.id,
      "story" => build(:runner_story, %{"id" => story.id})
    })
  end

  defp reload(tenant_id, story_id) do
    {:ok, story} = Stories.get_story(tenant_id, story_id)
    story
  end

  defp claimed_entry(tenant_id, story_id) do
    AdminRepo.one!(
      from e in AuditChain.Entry,
        where: e.tenant_id == ^tenant_id and e.entity_id == ^story_id,
        where: e.action == "story_stage_claimed"
    )
  end

  defp session_dispatch_count(tenant_id, story_id) do
    AdminRepo.aggregate(
      from(d in Dispatch, where: d.tenant_id == ^tenant_id and d.story_id == ^story_id),
      :count,
      :id
    )
  end

  # Unlinked first: `leave/1` shuts the channel down with `{:shutdown, :left}`, and
  # `subscribe_and_join/3` linked it to the test process, so the exit would take the test with
  # it before a single assertion ran.
  defp disconnect(channel, runner) do
    Process.unlink(channel.channel_pid)
    leave(channel)
    wait_until_disconnected(runner)
  end

  # Presence untracks when the channel process EXITS, which happens after `leave/1` returns, so
  # this polls rather than asserting once. It needs a real pause between attempts: a tight
  # recursion spent all fifty in well under a millisecond and flaked roughly one run in four.
  defp wait_until_disconnected(runner, attempts \\ 100) do
    cond do
      Loopctl.Runners.live_metas(runner.tenant_id, runner.id) == [] ->
        :ok

      attempts == 0 ->
        flunk("the runner's presence entry never went away")

      true ->
        Process.sleep(20)
        wait_until_disconnected(runner, attempts - 1)
    end
  end

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
end
