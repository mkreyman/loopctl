defmodule Loopctl.Holders.RunnerSessionTest do
  @moduledoc """
  US-52.15: a runner session is a holder. A placement mints the session dispatch together with
  a `:runner_session` holder, the claim names it, the runner's accept names the real session
  id, the session's end (or any undo of the placement) ends it, and verify separates the
  implementing and verifying HOLDERS rather than their shared agent.

  The placement half runs over a joined runner socket, as `Loopctl.Delivery.PlacementTest`
  does; everything stays on this test's sandbox transaction.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query
  import Loopctl.Test.Placement

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Dispatches
  alias Loopctl.Holders
  alias Loopctl.Holders.Holder
  alias Loopctl.Progress
  alias Loopctl.Runners.DispatchLedger
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @reply_timeout 2_000

  describe "a placement" do
    setup :joined_runner

    test "TC-52.15.1: creates the session holder, and the claim and the key name it", ctx do
      %{runner: runner, story: story} = ctx

      assert {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      assert_push "dispatch", _pushed, @reply_timeout

      session = session_dispatch(runner.tenant_id, story.id)
      holder = Holders.holder_for_dispatch(runner.tenant_id, session.id)

      assert %Holder{kind: :runner_session, host: "x1", ended_at: nil} = holder
      assert holder.agent_id == runner.agent_id
      assert holder.dispatch_id == session.id
      assert holder.runner_dispatch_id == placed.dispatch_id
      refute placed.dispatch_id == session.id
      assert holder.session_id == "dispatch:#{session.id}"
      assert DateTime.compare(holder.lease_until, DateTime.utc_now()) == :gt

      assert AdminRepo.get!(ApiKey, session.api_key_id).holder_id == holder.id
      assert reload(runner.tenant_id, story.id).assigned_holder_id == holder.id
    end

    test "TC-52.15.2: an undone placement ends its holder and revokes its key", ctx do
      %{runner: runner, story: story, channel: channel} = ctx
      disconnect(channel, runner)

      assert {:error, :runner_not_connected} =
               place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))

      session = session_dispatch(runner.tenant_id, story.id)
      holder = Holders.holder_for_dispatch(runner.tenant_id, session.id)

      assert %Holder{ended_reason: :ended} = holder
      assert holder.ended_at
      assert AdminRepo.get!(ApiKey, session.api_key_id).revoked_at
      assert is_nil(reload(runner.tenant_id, story.id).assigned_holder_id)
    end

    test "TC-52.15.3: an accept naming the session writes it on the holder", ctx do
      %{runner: runner, story: story} = ctx
      {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      session_id = Ecto.UUID.generate()

      accept!(runner, placed, %{"session_id" => session_id, "worktree" => "/w/loop-1"})

      holder = by_wire(runner.tenant_id, placed.dispatch_id)
      assert holder.session_id == session_id
      assert holder.worktree == "/w/loop-1"
    end

    test "TC-52.15.3: a 1.34.0 accept is recorded and the holder keeps its placeholder", ctx do
      %{runner: runner, story: story} = ctx
      {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      before = by_wire(runner.tenant_id, placed.dispatch_id)

      record = accept!(runner, placed, %{})

      assert record.status == "accepted"
      holder = by_wire(runner.tenant_id, placed.dispatch_id)
      assert holder.session_id == "dispatch:#{holder.dispatch_id}"
      assert is_nil(holder.worktree)
      assert DateTime.compare(holder.last_seen_at, before.last_seen_at) in [:gt, :eq]
    end

    test "an accept naming a session id another live holder of the agent holds keeps the placeholder",
         ctx do
      %{runner: runner, story: story} = ctx
      {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      taken = "taken-#{System.unique_integer([:positive])}"

      {:ok, _other} =
        Holders.insert_runner_session(runner.tenant_id, %{
          agent_id: runner.agent_id,
          dispatch_id: Ecto.UUID.generate(),
          runner_dispatch_id: Ecto.UUID.generate(),
          host: "x1",
          lease_until: DateTime.add(DateTime.utc_now(), 600, :second)
        })
        |> then(fn {:ok, other} ->
          AdminRepo.update!(Ecto.Changeset.change(other, session_id: taken))
          {:ok, other}
        end)

      accept!(runner, placed, %{"session_id" => taken})

      holder = by_wire(runner.tenant_id, placed.dispatch_id)
      assert holder.session_id == "dispatch:#{holder.dispatch_id}"
    end

    test "TC-52.15.4: session_ended ends the holder once; its replay writes nothing", ctx do
      %{runner: runner, story: story} = ctx
      {:ok, placed} = place(ctx, build(:placement_dispatch, %{"story_id" => story.id}))
      accept!(runner, placed, %{"session_id" => Ecto.UUID.generate()})

      message = %{
        dispatch_id: placed.dispatch_id,
        claim_epoch: placed.claim_epoch,
        reason: "crashed"
      }

      assert {:ok, %{replayed?: false}} = end_session(runner, message)
      holder = by_wire(runner.tenant_id, placed.dispatch_id)
      assert holder.ended_at
      assert AdminRepo.get!(ApiKey, holder_key_id(holder)).revoked_at
      assert ended_audits(runner.tenant_id, holder.id) == 1

      assert {:ok, %{replayed?: true}} = end_session(runner, message)

      assert by_wire(runner.tenant_id, placed.dispatch_id).ended_at ==
               holder.ended_at

      assert ended_audits(runner.tenant_id, holder.id) == 1
    end
  end

  describe "the accept contract (1.35.0)" do
    @base %{
      "dispatch_id" => "6f1c0e2a-1b2c-4d3e-8f40-1a2b3c4d5e6f",
      "claim_epoch" => 3,
      "decision" => "accepted"
    }

    test "a session_id over 200 bytes is refused" do
      assert {:error, {:invalid, errors}} =
               RunnerContract.cast_dispatch_reply(
                 Map.put(@base, "session_id", String.duplicate("a", 201))
               )

      assert [_ | _] = errors
    end

    test "a session_id carrying NUL is refused" do
      assert {:error, {:invalid, errors}} =
               RunnerContract.cast_dispatch_reply(Map.put(@base, "session_id", "a" <> <<0>>))

      # Refused for every payload by `values_ok/1`, before the reply shape is read.
      assert Enum.any?(errors, &(&1 =~ "NUL"))
    end

    test "a refusal may not name a session" do
      refusal =
        @base
        |> Map.merge(%{"decision" => "refused", "reason" => "at_capacity"})
        |> Map.put("session_id", "s")

      assert {:error, {:invalid, _}} = RunnerContract.cast_dispatch_reply(refusal)
    end

    test "200 bytes and a worktree are accepted" do
      payload =
        Map.merge(@base, %{"session_id" => String.duplicate("a", 200), "worktree" => "/w"})

      assert {:ok, %{session_id: _, worktree: "/w"}} =
               RunnerContract.cast_dispatch_reply(payload)
    end
  end

  describe "TC-52.15.6: verify separates holders, not agents" do
    setup do
      ctx = fixture(:verify_ready_story, %{})

      # The verifier dispatch is minted for the IMPLEMENTER's agent on a separate root: every
      # fleet session shares one agent, which is the case this story exists for.
      {:ok, %{dispatch: verifier}} =
        Dispatches.create_dispatch(ctx.tenant.id, %{
          role: :orchestrator,
          agent_id: ctx.implementer_runner.agent_id,
          story_id: ctx.story.id
        })

      story =
        ctx.story
        |> Ecto.Changeset.change(
          agent_status: :reported_done,
          verifier_dispatch_id: verifier.id
        )
        |> AdminRepo.update!()

      Map.merge(ctx, %{story: story, verifier: verifier})
    end

    test "case 1: different holders pass the clause under one agent", ctx do
      implementer = holder!(ctx, ctx.implementer.id)
      _verifier = holder!(ctx, ctx.verifier.id)
      story = name_holder!(ctx.story, implementer)

      assert :ok = Progress.ensure_verify_allowed(story, agent(ctx), lineage(ctx))
    end

    test "case 2: the same holder on both sides is self_verify_blocked", ctx do
      verifier = holder!(ctx, ctx.verifier.id)
      story = name_holder!(ctx.story, verifier)

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, Ecto.UUID.generate(), lineage(ctx))
    end

    test "case 3: a verifier with no holder keeps the agent-equality refusal", ctx do
      implementer = holder!(ctx, ctx.implementer.id)
      story = name_holder!(ctx.story, implementer)

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, agent(ctx), lineage(ctx))
    end

    test "a story claimed before holders keeps the agent-equality refusal", ctx do
      _verifier = holder!(ctx, ctx.verifier.id)

      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(ctx.story, agent(ctx), lineage(ctx))
    end

    test "TC-52.15.7: another tenant's holder for the same dispatch id never matches", ctx do
      other = fixture(:tenant)
      runner = fixture(:stage_runner, %{tenant_id: other.id})

      {:ok, _foreign} =
        Holders.insert_runner_session(other.id, %{
          agent_id: runner.agent_id,
          dispatch_id: ctx.verifier.id,
          runner_dispatch_id: ctx.verifier.id,
          host: "x1",
          lease_until: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      assert is_nil(Holders.holder_for_dispatch(ctx.tenant.id, ctx.verifier.id))
      implementer = holder!(ctx, ctx.implementer.id)
      story = name_holder!(ctx.story, implementer)

      # Tenant A's verify therefore falls back to agent equality.
      assert {:error, :self_verify_blocked} =
               Progress.ensure_verify_allowed(story, agent(ctx), lineage(ctx))
    end
  end

  # --- helpers ---

  defp joined_runner(_ctx) do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "x1"})
    {_operator_raw, operator} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})

    {:ok, socket} =
      connect(RunnerSocket, %{}, connect_info: build(:runner_connect_info, %{token: raw}))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> runner.id,
        build(:runner_join_payload, %{"machine" => "x1"})
      )

    _ = :sys.get_state(channel.channel_pid)

    story = fixture(:ledger_story, %{tenant_id: runner.tenant_id})
    story = contract_and_queue(runner.tenant_id, story)

    %{runner: runner, channel: channel, story: story, operator: operator}
  end

  defp place(ctx, payload) do
    Placement.place(ctx.runner.tenant_id, ctx.runner.id, payload, api_key: ctx.operator)
  end

  defp accept!(runner, placed, fields) do
    {:ok, reply} =
      %{
        "dispatch_id" => placed.dispatch_id,
        "claim_epoch" => placed.claim_epoch,
        "decision" => "accepted"
      }
      |> Map.merge(fields)
      |> RunnerContract.cast_dispatch_reply()

    {:ok, record} = DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)
    record
  end

  defp end_session(runner, message) do
    RunnerStages.end_session(runner.tenant_id, runner.id, message, actor_id: runner.api_key_id)
  end

  defp holder_key_id(holder) do
    AdminRepo.one!(from k in ApiKey, where: k.holder_id == ^holder.id, select: k.id)
  end

  defp ended_audits(tenant_id, holder_id) do
    AdminRepo.aggregate(
      from(a in AuditLog,
        where: a.tenant_id == ^tenant_id and a.entity_id == ^holder_id and a.action == "ended"
      ),
      :count
    )
  end

  defp holder!(ctx, dispatch_id) do
    {:ok, holder} =
      Holders.insert_runner_session(ctx.tenant.id, %{
        agent_id: ctx.implementer_runner.agent_id,
        dispatch_id: dispatch_id,
        runner_dispatch_id: dispatch_id,
        host: "x1",
        lease_until: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    holder
  end

  defp name_holder!(story, holder),
    do: story |> Ecto.Changeset.change(assigned_holder_id: holder.id) |> AdminRepo.update!()

  defp agent(ctx), do: ctx.implementer_runner.agent_id

  # The verifier's own lineage, so the caller-lineage clause passes and the RECORDED
  # separation is what the test reaches.
  defp lineage(ctx), do: ctx.verifier.lineage_path

  # The holder the runner's messages reach: keyed by the WIRE dispatch id.
  defp by_wire(tenant_id, wire_id) do
    AdminRepo.one!(
      from h in Holder, where: h.tenant_id == ^tenant_id and h.runner_dispatch_id == ^wire_id
    )
  end
end
