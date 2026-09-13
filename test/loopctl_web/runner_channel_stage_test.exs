defmodule LoopctlWeb.RunnerChannelStageTest do
  @moduledoc """
  Issue #803, contract 1.4.0: the `stage` event on the runner channel.

  The transition logic, the epoch fence and the slot release are covered without a socket in
  `Loopctl.Delivery.RunnerStagesTest` (async). What is here is the WIRING that module cannot
  see: that the channel casts through the contract, meters the event with its own bucket,
  answers with the row, and maps each refusal onto the contract's published `reason` codes.

  `async: false` for the same reason as `LoopctlWeb.RunnerChannelDispatchTest`: the socket
  authenticates its runner through `Loopctl.AdminRepo` while the ledger and the stage row
  live on the RLS `Loopctl.Repo`, so the runner and its tenant must be COMMITTED to be
  visible to both, and a committed row is visible to every concurrently running async test.
  """

  use LoopctlWeb.ChannelCase, async: false

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.Stages
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @reply_timeout 2_000
  @epoch 3

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

    fixture(:story_stage, %{
      tenant_id: runner.tenant_id,
      story_id: story.id,
      stage: :implementing,
      claim_epoch: @epoch
    })

    %{runner: runner, channel: channel, story: story, dispatch_id: payload["dispatch_id"]}
  end

  defp stage_message(dispatch_id, attrs) do
    Map.merge(
      %{"dispatch_id" => dispatch_id, "claim_epoch" => @epoch},
      attrs
    )
  end

  defp refill_bucket(channel) do
    :sys.replace_state(channel.channel_pid, fn socket ->
      %{socket | assigns: %{socket.assigns | stage_bucket: :full}}
    end)
  end

  describe "stage" do
    test "advances the row and replies with it", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{"from" => "implementing", "to" => "reviewing"})
        )

      assert_reply ref, :ok, reply, @reply_timeout
      assert reply.stage == "reviewing"
      assert reply.claim_epoch == @epoch
      assert is_integer(reply.lock_version)
      assert Stages.get(runner.tenant_id, story.id).stage == :reviewing
    end

    test "carries the transition's effect identities", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx
      sha = String.duplicate("b", 40)

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{
            "from" => "implementing",
            "to" => "reviewing",
            "effects" => %{"head_sha" => sha}
          })
        )

      assert_reply ref, :ok, _, @reply_timeout
      assert Stages.get(runner.tenant_id, story.id).head_sha == sha
    end

    test "a stale epoch is refused with the contract's code and writes nothing", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{
            "from" => "implementing",
            "to" => "reviewing",
            "claim_epoch" => @epoch + 1
          })
        )

      assert_reply ref, :error, %{reason: "stale_claim_epoch"}, @reply_timeout
      assert Stages.get(runner.tenant_id, story.id).stage == :implementing
    end

    test "a transition the machine has no edge for never reaches the database", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{"from" => "implementing", "to" => "merged"})
        )

      assert_reply ref, :error, %{reason: "invalid_payload", details: details}, @reply_timeout
      assert Enum.any?(details, &String.contains?(&1, "not a transition a runner may report"))
      assert Stages.get(runner.tenant_id, story.id).stage == :implementing
    end

    test "an edge a runner may never report is refused by the contract", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      for edge <- ~w(runner_lost claim_released human_resolution) do
        refill_bucket(ctx.channel)

        ref =
          push(
            channel,
            "stage",
            stage_message(dispatch_id, %{
              "from" => "implementing",
              "to" => "queued",
              "edge" => edge
            })
          )

        assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
      end
    end

    test "a verdict another principal reaches is refused at the contract", ctx do
      # #824 round 1, finding 2. Each of these IS a transition the machine has; none is a
      # runner's to report. Refused by the cast, so none reaches a database transaction and
      # none can write a chain entry asserting a gate ruling that never ran.
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      for {from, to, edge} <- [
            {"ci", "escalated", "merge_gate"},
            {"deployed", "escalated", "verification_failed"},
            {"implementing", "failed", "budget_exceeded"}
          ] do
        refill_bucket(channel)

        ref =
          push(
            channel,
            "stage",
            stage_message(dispatch_id, %{
              "from" => from,
              "to" => to,
              "edge" => edge,
              "reason" => "trying it on"
            })
          )

        assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout
      end

      assert Stages.get(runner.tenant_id, story.id).stage == :implementing
    end

    test "a reason over the bound in CODEPOINTS is refused though maxLength admits it", ctx do
      # #824 round 1, finding 5. `maxLength` counts graphemes; the story_stages CHECK counts
      # codepoints. An emoji family is one grapheme and seven codepoints, so 1000 of them
      # sit inside maxLength 4000 and well past the CHECK's 4000 — and used to be cast
      # clean, then refused deeper where nothing could act on it.
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx
      reason = String.duplicate("👨‍👩‍👧‍👦", 1_000)

      assert String.length(reason) == 1_000
      assert reason |> String.to_charlist() |> length() == 7_000

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{
            "from" => "implementing",
            "to" => "escalated",
            "edge" => "session_escalated",
            "reason" => reason
          })
        )

      assert_reply ref, :error, %{reason: "invalid_payload", details: details}, @reply_timeout
      assert Enum.any?(details, &String.contains?(&1, "codepoints"))
      assert Stages.get(runner.tenant_id, story.id).stage == :implementing
    end

    test "a replay is answered ok with the row, not stale_stage", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx
      message = stage_message(dispatch_id, %{"from" => "implementing", "to" => "reviewing"})

      ref = push(channel, "stage", message)
      assert_reply ref, :ok, first, @reply_timeout

      refill_bucket(channel)
      ref = push(channel, "stage", message)
      assert_reply ref, :ok, second, @reply_timeout

      assert second.lock_version == first.lock_version
      assert second.stage == "reviewing"
    end

    test "a terminal outcome releases the session's slot", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner} = ctx

      assert %{released_at: nil} = DispatchLedger.get_record(runner.tenant_id, dispatch_id)

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{
            "from" => "implementing",
            "to" => "escalated",
            "edge" => "session_escalated",
            "reason" => "the request contradicts US-3.1"
          })
        )

      assert_reply ref, :ok, reply, @reply_timeout
      assert reply.stage == "escalated"

      record = DispatchLedger.get_record(runner.tenant_id, dispatch_id)
      refute is_nil(record.released_at)
    end

    test "entering escalated with no reason is refused before the database", ctx do
      %{channel: channel, dispatch_id: dispatch_id, runner: runner, story: story} = ctx

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{
            "from" => "implementing",
            "to" => "escalated",
            "edge" => "session_escalated"
          })
        )

      assert_reply ref, :error, %{reason: "invalid_payload", details: details}, @reply_timeout
      assert Enum.any?(details, &String.contains?(&1, "reason is required"))
      assert Stages.get(runner.tenant_id, story.id).stage == :implementing
    end

    test "another runner's dispatch is unknown_dispatch", ctx do
      %{channel: channel, runner: runner} = ctx

      {raw_b, runner_b} =
        fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      {:ok, socket_b} = connect(RunnerSocket, %{}, connect_info: connect_info(raw_b))

      {:ok, _reply, channel_b} =
        subscribe_and_join(socket_b, "runner:" <> runner_b.id, join_payload("blockit"))

      _ = :sys.get_state(channel_b.channel_pid)

      ref =
        push(
          channel_b,
          "stage",
          stage_message(ctx.dispatch_id, %{"from" => "implementing", "to" => "reviewing"})
        )

      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
      _ = channel
    end

    # The bucket, in two DETERMINISTIC halves. Draining it with a burst of `capacity + 1` real
    # pushes is the obvious test and it is a flake: every push is a database round trip, the
    # bucket earns a token every 250 ms, and under a loaded full suite the burst outlasts the
    # refill — green alone, red in `mix test` (#824 round 1). Neither assertion below reads
    # the wall clock.
    test "a push spends one of the tokens the CONTRACT publishes", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx
      capacity = RunnerContract.stage_burst() |> Map.fetch!("capacity")

      # A valid message — an invalid one is refused before the bucket and spends nothing.
      # It refuses on the compare-and-set, which is beside the point here.
      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{"from" => "reviewing", "to" => "pr_open"})
        )

      assert_reply ref, :error, %{reason: "stale_stage"}, @reply_timeout

      # ONE push against a `:full` bucket, so the token count is exactly `capacity - 1`
      # however long the round trip took. This is what binds the channel's constant to the
      # contract's number: a channel enforcing a different capacity lands on a different count.
      assert {tokens, _refilled_at} = :sys.get_state(channel.channel_pid).assigns.stage_bucket
      assert tokens == capacity - 1
    end

    test "an exhausted bucket refuses with the contract's interval", ctx do
      %{channel: channel, dispatch_id: dispatch_id} = ctx

      # Zero tokens, last one earned an hour into the FUTURE, so `earned` is clamped to 0 and
      # no amount of elapsed test time can refill it. The refusal is the channel's, not the
      # clock's.
      :sys.replace_state(channel.channel_pid, fn socket ->
        future = System.monotonic_time(:millisecond) + 3_600_000
        %{socket | assigns: %{socket.assigns | stage_bucket: {0, future}}}
      end)

      ref =
        push(
          channel,
          "stage",
          stage_message(dispatch_id, %{"from" => "implementing", "to" => "reviewing"})
        )

      assert_reply ref, :error, %{reason: "rate_limited", min_interval_ms: ms}, @reply_timeout
      assert ms == RunnerContract.stage_burst() |> Map.fetch!("refill_interval_ms")

      # And nothing was written: a message refused by the bucket never reaches the machine.
      assert Stages.get(ctx.runner.tenant_id, ctx.story.id).stage == :implementing
    end
  end
end
