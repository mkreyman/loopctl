defmodule Loopctl.Agents.TuningFlowTest do
  @moduledoc """
  US-48.13 end to end through a real runner socket: the tuning pass sends a STORY-LESS
  `spec_tune` dispatch built from the target spec's failed runs, the runner accepts it, and its
  `agent_result` is stored under the status loopctl decides — never the runner's.

  This is the test of the story-less ledger path (contract 1.30.0): a dispatch with no
  `story_id` is recorded, pushed, accepted and answered with `claim_epoch` 0, its reservation
  is released by the answer, and a halted tenant is sent nothing.
  """

  use LoopctlWeb.ChannelCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.RunOutcome
  alias Loopctl.Agents.Tuning
  alias Loopctl.Agents.TuningDraft
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Runners
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  @reply_timeout 2_000
  @budgets %{wall_clock_seconds: 900, max_turns: 30}

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    {raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis", max_sessions: 9})
    story = fixture(:ledger_story, %{tenant_id: tenant.id})
    fixture(:intake_source, %{tenant_id: tenant.id, project_id: story.project_id})

    overridden =
      fixture(:agent_run_outcome, %{
        tenant_id: tenant.id,
        story: story,
        spec_id: "triage",
        archetype: "judge",
        end_reason: "triage_verdict",
        signals: %{
          "verdict" => %{"value" => %{"outcome" => "escalate", "destination" => "escalated"}},
          "human_override" => %{"value" => true},
          "human_route" => %{"value" => "queued"}
        }
      })

    clean =
      fixture(:agent_run_outcome, %{
        tenant_id: tenant.id,
        story: story,
        spec_id: "triage",
        archetype: "judge",
        end_reason: "triage_verdict"
      })

    %{
      tenant: tenant,
      runner: runner,
      runner_key: raw,
      story: story,
      overridden: overridden,
      clean: clean
    }
  end

  defp run_pass(opts \\ []),
    do:
      Tuning.run(Keyword.merge([limit: 5, enabled?: true, budgets: @budgets, min_rows: 2], opts))

  defp good_result(trace_id) do
    %{
      "new_cases" => [
        %{
          "name" => "t90_override_queued",
          "source_trace_id" => trace_id,
          "description" => "A human queued what triage escalated.",
          "fixture" => %{
            "repo" => "fixtures/tiny_app.json",
            "commit" => String.duplicate("a", 40)
          },
          "expectations" => %{
            "schema_valid" => true,
            "outcomes_allowed" => ["story"],
            "escalation_codes" => [],
            "lens_agreement" => nil,
            "forbidden" => [],
            "screens" => [],
            "rubric" => nil
          }
        }
      ],
      "proposed_template" => %{
        "id" => "triage",
        "from_version" => 1,
        "to_version" => 2,
        "diff" => "--- a\n+++ b\n@@\n-old\n+new\n"
      },
      "scores" => %{
        "current" => %{"passed" => 1, "total" => 2},
        "proposed" => %{"passed" => 2, "total" => 2},
        "per_case" => [
          %{"case" => "t01", "existing" => true, "current" => true, "proposed" => true},
          %{
            "case" => "t90_override_queued",
            "existing" => false,
            "current" => false,
            "proposed" => true
          }
        ]
      }
    }
  end

  describe "a tuning run, through the runner socket" do
    test "TC-48.13.1: the override becomes a trace expecting the human's route, and the result is stored as loopctl decides",
         ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})

      assert {:ok, [{candidate, :dispatched}]} = run_pass()
      assert candidate.spec_id == "triage" and candidate.outcome_rows == 2

      assert_push "dispatch", pushed, @reply_timeout

      # No story, a zero epoch, and the spec_tune object as the contract casts it.
      refute Map.has_key?(pushed, :story_id)
      assert pushed.kind == "spec_tune" and pushed.claim_epoch == 0
      assert {:ok, _} = RunnerContract.cast_dispatch(pushed)

      assert %{traces: [trace]} = pushed.spec_tune
      assert pushed.spec_tune.template == %{id: "triage", version: 1}
      assert pushed.spec_tune.eval_set == "triage@1"
      assert trace.trace_id == ctx.overridden.dispatch_id
      assert trace.failures == ["human_override"]
      assert trace.agent_decision == %{outcome: "escalate"}
      assert trace.human_decision == %{route: "queued", outcomes: ["story"]}
      assert trace.untrusted =~ "⟦UNTRUSTED DATA field=traced_story"
      assert trace.untrusted =~ "| " <> ctx.story.title

      ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
      assert_reply ref, :ok, _ack, @reply_timeout

      ref = push(channel, "agent_result", agent_result(pushed, good_result(trace.trace_id)))
      assert_reply ref, :ok, _ack, @reply_timeout

      draft = draft!(pushed.dispatch_id)
      assert draft.status == :proposed
      assert draft.rejection_reasons == []
      assert draft.to_version == 2
      assert [%{"source_trace_id" => trace_id}] = draft.new_cases["cases"]
      assert trace_id == ctx.overridden.dispatch_id
      assert %{"traces" => [%{"human_decision" => %{"outcomes" => ["story"]}}]} = draft.input

      # The answer released the reservation and recorded the run's own outcome row, story-less.
      record =
        AdminRepo.one!(from r in DispatchRecord, where: r.dispatch_id == ^pushed.dispatch_id)

      assert record.story_id == nil and not is_nil(record.released_at)

      outcome = AdminRepo.one!(from o in RunOutcome, where: o.dispatch_id == ^pushed.dispatch_id)
      assert outcome.spec_id == "spec_tuner" and outcome.story_id == nil
      assert outcome.signals["tuning_status"]["value"] == "proposed"

      leave_channel(channel)
    end

    test "TC-48.13.2 through the socket: the runner's scores do not decide; a regression rejects",
         ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout

      ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
      assert_reply ref, :ok, _ack, @reply_timeout

      [trace] = pushed.spec_tune.traces

      regressing =
        put_in(good_result(trace.trace_id), ["scores"], %{
          "current" => %{"passed" => 1, "total" => 3},
          "proposed" => %{"passed" => 2, "total" => 3},
          "per_case" => [
            %{"case" => "t01", "existing" => true, "current" => true, "proposed" => false},
            %{"case" => "t02", "existing" => true, "current" => false, "proposed" => true},
            %{
              "case" => "t90_override_queued",
              "existing" => false,
              "current" => false,
              "proposed" => true
            }
          ]
        })

      ref = push(channel, "agent_result", agent_result(pushed, regressing))
      assert_reply ref, :ok, _ack, @reply_timeout

      draft = draft!(pushed.dispatch_id)
      assert draft.status == :rejected
      assert draft.rejection_reasons == ["regression"]

      leave_channel(channel)
    end

    test "a result whose schema fails is refused and the draft stays pending", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout

      ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
      assert_reply ref, :ok, _ack, @reply_timeout

      [trace] = pushed.spec_tune.traces
      missing_scores = Map.delete(good_result(trace.trace_id), "scores")

      ref = push(channel, "agent_result", agent_result(pushed, missing_scores))
      assert_reply ref, :error, %{reason: "invalid_payload"}, @reply_timeout

      assert draft!(pushed.dispatch_id).status == :pending

      leave_channel(channel)
    end

    test "a second pass while one is pending sends nothing", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", _pushed, @reply_timeout

      assert {:ok, []} = run_pass()
      refute_push "dispatch", _again, 200

      leave_channel(channel)
    end

    test "a runner that does not declare spec_tune is sent nothing", ctx do
      channel = join_runner(ctx, %{"kinds" => ["triage"]})

      assert {:ok, [{_candidate, :no_runner}]} = run_pass()
      refute_push "dispatch", _pushed, 200
      assert drafts(ctx.tenant.id) == []

      leave_channel(channel)
    end

    test "a refused push deletes the pending row it inserted; a raise leaves it to the sweep",
         ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})

      refuse = fn _tenant, _runner, _payload -> {:error, :runner_at_capacity} end
      assert {:ok, [{_candidate, :deferred}]} = run_pass(dispatch: refuse)
      assert drafts(ctx.tenant.id) == []

      crash = fn _tenant, _runner, _payload -> raise "socket gone" end
      assert {:ok, [{_candidate, :errored}]} = run_pass(dispatch: crash)
      assert [%TuningDraft{status: :pending} = pending] = drafts(ctx.tenant.id)

      # Held while it is younger than the grace; abandoned after it, which frees the pair.
      assert {:ok, []} = run_pass(dispatch: crash)
      later = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      assert Tuning.abandon_stale(later) >= 1
      assert AdminRepo.get!(TuningDraft, pending.id).status == :abandoned

      leave_channel(channel)
    end

    test "a pending draft whose dispatch still holds a slot is never abandoned", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout

      # A story-less reservation names no claim, so the capacity heal's claim fence must not
      # read it as dead the moment it was taken.
      record =
        AdminRepo.one!(from r in DispatchRecord, where: r.dispatch_id == ^pushed.dispatch_id)

      dead = AdminRepo.all(Capacity.dead_reservations(DateTime.utc_now()))
      refute record.id in dead

      later = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      _ = Tuning.abandon_stale(later)
      assert draft!(pushed.dispatch_id).status == :pending

      leave_channel(channel)
    end

    test "a spec_tune result touches no story, no stage row and no story audit entry", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})

      snapshot = fn ->
        {AdminRepo.all(from s in Story, where: s.tenant_id == ^ctx.tenant.id),
         AdminRepo.all(from s in StoryStage, where: s.tenant_id == ^ctx.tenant.id),
         AdminRepo.all(
           from a in AuditLog,
             where: a.tenant_id == ^ctx.tenant.id and a.entity_type in ["story", "story_stage"]
         )}
      end

      before = snapshot.()

      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout
      ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
      assert_reply ref, :ok, _ack, @reply_timeout
      [trace] = pushed.spec_tune.traces
      ref = push(channel, "agent_result", agent_result(pushed, good_result(trace.trace_id)))
      assert_reply ref, :ok, _ack, @reply_timeout

      assert draft!(pushed.dispatch_id).status == :proposed
      assert snapshot.() == before

      leave_channel(channel)
    end

    test "a result is accepted once, for this runner's own live, unrevoked ledger row", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout

      [trace] = pushed.spec_tune.traces
      result = agent_result(pushed, good_result(trace.trace_id))

      # Not yet accepted: refused, nothing stored.
      ref = push(channel, "agent_result", result)
      assert_reply ref, :error, %{reason: "dispatch_not_accepted"}, @reply_timeout

      ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
      assert_reply ref, :ok, _ack, @reply_timeout

      # Another dispatch id: not this runner's row.
      ref =
        push(channel, "agent_result", %{result | "dispatch_id" => Ecto.UUID.generate()})

      assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout

      ref = push(channel, "agent_result", result)
      assert_reply ref, :ok, %{replayed: false}, @reply_timeout

      # Idempotent on dispatch_id: the same bytes replay, different bytes are refused. Applied
      # directly, past the channel's per-message rate limit, through the path it calls.
      apply = fn message ->
        {:ok, cast} = RunnerContract.cast_agent_result_message(message)
        AgentResult.apply(ctx.tenant.id, ctx.runner.id, cast)
      end

      assert {:ok, %{replayed?: true}} = apply.(result)

      different = put_in(result, ["result", "proposed_template", "diff"], "+other\n")
      assert apply.(different) == {:error, :already_recorded}

      assert draft!(pushed.dispatch_id).diff == "--- a\n+++ b\n@@\n-old\n+new\n"

      leave_channel(channel)
    end

    test "a released or revoked story-less row takes no first result", ctx do
      for gone <- [:released, :revoked] do
        channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
        assert {:ok, [{_candidate, :dispatched}]} = run_pass()
        assert_push "dispatch", pushed, @reply_timeout

        ref = push(channel, "dispatch_reply", reply(pushed, "accepted"))
        assert_reply ref, :ok, _ack, @reply_timeout

        record_q = from r in DispatchRecord, where: r.dispatch_id == ^pushed.dispatch_id

        case gone do
          :released ->
            {1, _} = AdminRepo.update_all(record_q, set: [released_at: DateTime.utc_now()])

          :revoked ->
            {1, _} =
              AdminRepo.update_all(
                from(r in Runner, where: r.id == ^ctx.runner.id),
                set: [revoked_at: DateTime.utc_now()]
              )
        end

        [trace] = pushed.spec_tune.traces
        ref = push(channel, "agent_result", agent_result(pushed, good_result(trace.trace_id)))
        assert_reply ref, :error, %{reason: "unknown_dispatch"}, @reply_timeout
        assert draft!(pushed.dispatch_id).status == :pending, "#{gone}"

        # Free the pair and the runner for the next round.
        {1, _} =
          AdminRepo.update_all(
            from(d in TuningDraft, where: d.dispatch_id == ^pushed.dispatch_id),
            set: [status: :abandoned]
          )

        {1, _} = AdminRepo.update_all(record_q, set: [released_at: DateTime.utc_now()])

        AdminRepo.update_all(from(r in Runner, where: r.id == ^ctx.runner.id),
          set: [revoked_at: nil, in_flight: 0]
        )

        leave_channel(channel)
      end
    end

    test "a story-less ledger or outcome row is refused for every kind but spec_tune", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})
      assert {:ok, [{_candidate, :dispatched}]} = run_pass()
      assert_push "dispatch", pushed, @reply_timeout

      record_q = from r in DispatchRecord, where: r.dispatch_id == ^pushed.dispatch_id

      for kind <- Kinds.all() -- ["spec_tune"] do
        assert_raise Postgrex.Error, ~r/runner_dispatches_story_shape/, fn ->
          AdminRepo.transaction(fn -> AdminRepo.update_all(record_q, set: [kind: kind]) end)
        end
      end

      # ...and a spec_tune row may not name a story.
      assert_raise Postgrex.Error, ~r/runner_dispatches_story_shape/, fn ->
        AdminRepo.transaction(fn ->
          AdminRepo.update_all(record_q, set: [story_id: ctx.story.id])
        end)
      end

      # The ledger path: a story-anchored kind with no story is refused at the cast, before
      # any row is written.
      for kind <- Kinds.all() -- ["spec_tune"] do
        payload = %{
          "dispatch_id" => Ecto.UUID.generate(),
          "kind" => kind,
          "repo" => pushed.repo,
          "base_branch" => "master",
          "branch" => "master",
          "claim_epoch" => 0,
          "wall_clock_seconds" => 600,
          "max_turns" => 10
        }

        assert {:error, _} = Runners.dispatch(ctx.tenant.id, ctx.runner.id, payload)

        refute AdminRepo.exists?(
                 from r in DispatchRecord, where: r.dispatch_id == ^payload["dispatch_id"]
               )
      end

      leave_channel(channel)
    end

    test "a halted tenant is sent nothing, and the pending row it inserted is gone", ctx do
      channel = join_runner(ctx, %{"kinds" => ["spec_tune"]})

      {1, _} =
        AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant.id),
          set: [custody_halted_at: DateTime.utc_now()]
        )

      assert {:ok, [{_candidate, outcome}]} = run_pass()
      assert outcome in [:deferred, :blocked, :no_runner]
      refute_push "dispatch", _pushed, 200
      assert drafts(ctx.tenant.id) == []
      assert AdminRepo.all(from r in DispatchRecord, where: r.tenant_id == ^ctx.tenant.id) == []

      leave_channel(channel)
    end
  end

  defp draft!(dispatch_id),
    do: AdminRepo.one!(from d in TuningDraft, where: d.dispatch_id == ^dispatch_id)

  defp drafts(tenant_id),
    do: AdminRepo.all(from d in TuningDraft, where: d.tenant_id == ^tenant_id)

  defp reply(pushed, decision),
    do: %{"dispatch_id" => pushed.dispatch_id, "claim_epoch" => 0, "decision" => decision}

  defp agent_result(pushed, result),
    do: %{
      "dispatch_id" => pushed.dispatch_id,
      "claim_epoch" => 0,
      "spec" => %{"id" => "spec_tuner", "version" => 1},
      "result" => result
    }

  defp join_runner(ctx, overrides) do
    {:ok, socket} = connect(RunnerSocket, %{}, connect_info: connect_info(ctx.runner_key))

    {:ok, _reply, channel} =
      subscribe_and_join(
        socket,
        "runner:" <> ctx.runner.id,
        Map.merge(join_payload("minis"), overrides)
      )

    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  defp leave_channel(channel) do
    Process.unlink(channel.channel_pid)
    leave(channel)
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
      "repos" => [],
      "max_sessions" => 9,
      "in_flight" => 0,
      "draining" => false
    }
  end
end
