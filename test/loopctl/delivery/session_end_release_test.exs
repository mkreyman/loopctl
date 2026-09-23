defmodule Loopctl.Delivery.SessionEndReleaseTest do
  @moduledoc """
  US-44.3: the `session_ended` reasons that END THE CLAIM — `crashed` and `usage_exhausted`,
  which re-queue the story, and the budget kills, which escalate it first — end to end through
  `Loopctl.Delivery.RunnerStages.end_session/3`.

  `async: false`, and COMMITTED rather than sandboxed, for the reason
  `Loopctl.Delivery.PlacementTest` gives: the path spans BOTH repos. The report is recorded on
  the dispatch ledger (the RLS `Loopctl.Repo`) and the release is an `AdminRepo` transaction,
  and the two sandbox connections neither see each other's uncommitted rows nor let go of the
  locks they took — the ledger's `FOR SHARE` on the story would hold the release's `FOR UPDATE`
  until its lock timeout. `sweep_committed_runner_tenants/0` removes everything, chain entries
  included. The Repo-only reasons and every refusal are in `Loopctl.Delivery.SessionEndTest`.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Delivery.Placement
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Usage
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  # A story claimed by the runner's own agent with a full 24h lease — 23h and more still to
  # run, so only the report can release it — its stage row at `implementing` under that claim,
  # and an ACCEPTED implement dispatch holding one slot on the runner.
  setup do
    tenant = fixture(:committed_tenant, %{})
    {_raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    story = fixture(:committed_story, %{tenant_id: tenant.id})

    {story, record} =
      unboxed(fn ->
        {:ok, story} =
          Progress.contract_story(tenant.id, story.id, %{},
            actor_label: "test",
            skip_contract_check: true
          )

        {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: runner.agent_id)

        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: tenant.id,
          story_id: story.id,
          stage: :implementing,
          claim_epoch: claimed.claim_epoch
        })

        record =
          fixture(:accepted_dispatch, %{
            tenant_id: tenant.id,
            runner: runner,
            story_id: story.id,
            claim_epoch: claimed.claim_epoch
          })

        {claimed, record}
      end)

    %{tenant_id: tenant.id, runner: runner, story: story, record: record}
  end

  defp end_session(ctx, reason) do
    unboxed(fn ->
      RunnerStages.end_session(ctx.tenant_id, ctx.runner.id, %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        reason: reason
      })
    end)
  end

  defp unboxed(fun),
    do: Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)

  defp story(ctx), do: unboxed(fn -> AdminRepo.get!(Story, ctx.story.id) end)

  defp runner_in_flight(ctx),
    do: unboxed(fn -> AdminRepo.get!(Runner, ctx.runner.id).in_flight end)

  defp ledger(ctx), do: unboxed(fn -> AdminRepo.get!(DispatchRecord, ctx.record.id) end)

  defp releases(ctx) do
    unboxed(fn ->
      AdminRepo.all(
        from a in AuditLog,
          where: a.tenant_id == ^ctx.tenant_id and a.entity_id == ^ctx.story.id,
          where: a.action == "claim_session_ended"
      )
    end)
  end

  defp requeues(ctx) do
    unboxed(fn ->
      AdminRepo.all(
        from e in StageEvent,
          where: e.tenant_id == ^ctx.tenant_id and e.story_id == ^ctx.story.id,
          where: e.event == "transitioned",
          select: {e.from_stage, e.to_stage, e.edge}
      )
    end)
  end

  test "crashed releases the claim before the lease runs out, over runner_lost (AC-44.3.4)",
       ctx do
    assert DateTime.diff(ctx.story.claimed_until, DateTime.utc_now(), :hour) >= 23
    assert runner_in_flight(ctx) == 1

    assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "crashed")

    released = story(ctx)
    assert released.agent_status == :pending
    assert released.assigned_agent_id == nil
    assert released.claim_epoch == ctx.story.claim_epoch + 1

    # The ack is the row AFTER the release: back in the queue, under the new claim epoch.
    assert row.stage == :queued
    assert row.claim_epoch == released.claim_epoch
    assert row.attempts == %{"runner_lost" => 1}
    assert requeues(ctx) == [{"implementing", "queued", "runner_lost"}]

    # The reclaim's audit shape, naming the report rather than a lease that did not expire —
    # and attributed to the runner's KEY, the principal the label names.
    assert [%AuditLog{actor_type: "api_key", actor_id: actor_id, actor_label: label} = entry] =
             releases(ctx)

    assert actor_id == ctx.runner.api_key_id
    assert label == "runner:" <> ctx.runner.id
    assert entry.new_state["session_ended_reason"] == "crashed"

    # The claim the session ran under has ended, so its slot goes back now rather than at the
    # heal sweep — and a crash IS an attempt against the retry ceiling.
    assert runner_in_flight(ctx) == 0
    assert ledger(ctx).counts_toward_retry_ceiling == true
  end

  test "a resend after the release is answered ok with the row, and releases once (AC-44.3.2)",
       ctx do
    assert {:ok, %{row: first, replayed?: false}} = end_session(ctx, "crashed")

    # The epoch the resend carries is the one its own first copy moved on from. It is matched
    # on its bytes before the fence, so it is still the report that was recorded.
    assert {:ok, %{row: again, replayed?: true}} = end_session(ctx, "crashed")

    assert again.stage == :queued
    assert again.lock_version == first.lock_version
    assert story(ctx).claim_epoch == ctx.story.claim_epoch + 1
    assert length(releases(ctx)) == 1
    assert length(requeues(ctx)) == 1
    assert runner_in_flight(ctx) == 0
  end

  test "usage_exhausted releases the same way and is NOT a counted attempt (AC-44.3.5)", ctx do
    assert {:ok, %{row: row}} = end_session(ctx, "usage_exhausted")

    assert row.stage == :queued
    # Re-queued over the same edge a crash takes, and NOT counted on the row: the work was
    # never judged, so it must not spend an attempt.
    assert requeues(ctx) == [{"implementing", "queued", "runner_lost"}]
    assert row.attempts == %{}
    assert story(ctx).agent_status == :pending
    assert [%AuditLog{new_state: %{"session_ended_reason" => "usage_exhausted"}}] = releases(ctx)

    recorded = ledger(ctx)
    assert recorded.session_ended_reason == "usage_exhausted"
    assert recorded.counts_toward_retry_ceiling == false
    assert runner_in_flight(ctx) == 0
  end

  test "a FIRST report for a claim that already ended some other way releases nothing", ctx do
    # A lease reclaim, an operator unclaim — anything that ended this claim BEFORE the report
    # arrived. A first report is fenced like every runner message: refused, and neither
    # recorded nor acted on, so it can never take the claim that came after.
    unboxed(fn -> {:ok, _} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id) end)
    after_unclaim = story(ctx)

    assert {:error, :stale_claim_epoch} = end_session(ctx, "crashed")

    assert story(ctx).claim_epoch == after_unclaim.claim_epoch
    assert releases(ctx) == []
    assert ledger(ctx).session_ended_reason == nil
    assert unboxed(fn -> Stages.get(ctx.tenant_id, ctx.story.id) end).stage == :queued
  end

  describe "a budget kill (AC-44.3.3)" do
    test "escalates the story, then ENDS its claim as the session end, never re-queueing it",
         ctx do
      assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "wall_clock_exceeded")

      released = story(ctx)
      assert released.agent_status == :pending
      assert released.assigned_agent_id == nil
      assert released.claim_epoch == ctx.story.claim_epoch + 1

      # Escalated and STAYS escalated: the release only rebinds it to the new epoch.
      assert row.stage == :escalated
      assert row.claim_epoch == released.claim_epoch
      assert row.attempts == %{"budget_reported" => 1}
      assert requeues(ctx) == [{"implementing", "escalated", "budget_reported"}]

      # Audited as the session end it was, not as a lease that expired a day later.
      assert [%AuditLog{actor_type: "api_key", new_state: new_state}] = releases(ctx)
      assert new_state["session_ended_reason"] == "wall_clock_exceeded"

      assert runner_in_flight(ctx) == 0
      assert ledger(ctx).counts_toward_retry_ceiling == nil
    end

    test "a resend escalates nothing and ends nothing twice", ctx do
      assert {:ok, %{row: first}} = end_session(ctx, "max_turns_exceeded")
      assert {:ok, %{row: again, replayed?: true}} = end_session(ctx, "max_turns_exceeded")

      assert again.lock_version == first.lock_version
      assert length(releases(ctx)) == 1
      assert length(requeues(ctx)) == 1
      assert story(ctx).claim_epoch == ctx.story.claim_epoch + 1
    end
  end

  describe "the record comes first, and a resend RE-DRIVES the action" do
    # What a node dying between the two writes leaves: the report is on the ledger row and the
    # release never ran. Written here the way `end_session/3` writes it, so the resend meets
    # exactly the record its first copy would have left.
    defp record_only(ctx, reason) do
      message = %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        reason: reason
      }

      unboxed(fn ->
        DispatchLedger.record_session_end(ctx.tenant_id, ctx.runner.id, message, %{
          reason: reason,
          digest: TriageVerdictRecord.digest(message),
          counts_toward_retry_ceiling:
            Map.get(%{"crashed" => true, "usage_exhausted" => false}, reason),
          story_id: ctx.story.id
        })
      end)
    end

    test "a recorded crash whose release never ran is released by the resend", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "crashed")
      assert story(ctx).agent_status in [:assigned, :implementing]

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "crashed")

      assert row.stage == :queued
      assert story(ctx).agent_status == :pending
      assert length(releases(ctx)) == 1
      assert runner_in_flight(ctx) == 0
    end

    test "a recorded budget kill that escalated nothing is escalated and ended by the resend",
         ctx do
      # What a permanent-looking failure of the escalation used to strand: the report on the
      # ledger, the row still in flight, the claim still held. The resend is the only way the
      # work completes, which is why that failure is now answered as a retry.
      assert {:ok, {:recorded, _session}} = record_only(ctx, "wall_clock_exceeded")

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")

      assert row.stage == :escalated
      assert story(ctx).agent_status == :pending
      assert length(releases(ctx)) == 1
      assert requeues(ctx) == [{"implementing", "escalated", "budget_reported"}]
    end

    test "an escalation that landed without its release is released once by the resend", ctx do
      assert {:ok, {:recorded, session}} = record_only(ctx, "wall_clock_exceeded")

      {:ok, _escalated} =
        unboxed(fn ->
          Stages.advance(
            ctx.tenant_id,
            ctx.story.id,
            {:implementing, :escalated, :budget_reported},
            claim_epoch: ctx.record.claim_epoch,
            reason: "session_ended:wall_clock_exceeded",
            actor_role: :agent,
            actor_lineage: [],
            session_dispatch: {ctx.record.dispatch_id, session.slot_generation}
          )
        end)

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")

      assert row.stage == :escalated
      assert row.attempts == %{"budget_reported" => 1}
      assert story(ctx).agent_status == :pending
      assert length(releases(ctx)) == 1
    end

    test "and never releases a claim that ended some other way in between", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "crashed")
      unboxed(fn -> {:ok, _} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id) end)
      after_unclaim = story(ctx)

      assert {:ok, %{replayed?: true}} = end_session(ctx, "crashed")

      assert story(ctx).claim_epoch == after_unclaim.claim_epoch
      assert releases(ctx) == []
      # That claim ended, so the session's slot is free either way.
      assert runner_in_flight(ctx) == 0
    end
  end

  describe "usage_exhausted marks the RUNNER exhausted (US-44.6, AC-44.6.4)" do
    @eight_days 8 * 24 * 60 * 60

    test "the runner is held out for eight days, so the re-queued story is not offered back to it",
         ctx do
      assert {:ok, %{row: %{stage: :queued}}} = end_session(ctx, "usage_exhausted")

      assert_in_delta seconds_from_now(usage_until(ctx)), @eight_days, 5

      # THE LOOP THIS CLOSES. The release above re-queued the story WITHOUT spending an
      # attempt, so nothing bounded how often it could be placed straight back on this machine,
      # whose every session ends the same way. The machine now reads as exhausted — which the
      # selectors' query excludes — and an operator's placement naming it outright is refused.
      assert unboxed(fn -> Runners.usage_exhausted?(ctx.tenant_id, ctx.runner.id) end)

      unboxed(fn ->
        {1, _} =
          AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
            set: [trust_tier: :human_anchored]
          )
      end)

      {_raw, operator} = fixture(:committed_operator_key, %{tenant_id: ctx.tenant_id})

      assert {:error, :runner_exhausted} =
               unboxed(fn ->
                 Placement.place(
                   ctx.tenant_id,
                   ctx.runner.id,
                   %{"dispatch_id" => Ecto.UUID.generate(), "story_id" => ctx.story.id},
                   api_key: operator,
                   actor_label: "test"
                 )
               end)
    end

    test "a crash does not mark the runner: the machine is fine, the session was not", ctx do
      assert {:ok, _} = end_session(ctx, "crashed")
      assert usage_until(ctx) == nil
    end

    test "a resend after the account was reported refilled does NOT re-exhaust it", ctx do
      assert {:ok, %{replayed?: false}} = end_session(ctx, "usage_exhausted")

      assert :ok =
               unboxed(fn -> Usage.record(ctx.tenant_id, ctx.runner.id, %{exhausted: false}) end)

      # The honest resend of the report that released the claim. Its claim is over — the epoch
      # has moved on — so it is completing nothing, and re-marking would hold the machine out
      # for eight days on a fact the runner has since corrected.
      assert {:ok, %{replayed?: true}} = end_session(ctx, "usage_exhausted")

      assert usage_until(ctx) == nil
    end

    # The FIRST delivery, but late: a peer on the same account reported it refilled after this
    # session's dispatch was accepted, so the session's exhaustion is the older fact. The claim
    # is still released — the session is over either way — but the account is not re-marked.
    test "a late first report after a peer reported the account refilled does not re-mark it",
         ctx do
      {_raw, peer} = fixture(:committed_runner, %{tenant_id: ctx.tenant_id, name: "beelink"})

      unboxed(fn ->
        :ok = Usage.record(ctx.tenant_id, ctx.runner.id, %{exhausted: true, account_ref: "a"})
        :ok = Usage.record(ctx.tenant_id, peer.id, %{exhausted: false, account_ref: "a"})
      end)

      assert {:ok, %{row: %{stage: :queued}, replayed?: false}} =
               end_session(ctx, "usage_exhausted")

      assert usage_until(ctx) == nil
      assert length(releases(ctx)) == 1
    end

    test "a recorded report whose mark and release never ran is completed by the resend", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "usage_exhausted")
      assert usage_until(ctx) == nil

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "usage_exhausted")

      assert row.stage == :queued
      assert_in_delta seconds_from_now(usage_until(ctx)), @eight_days, 5
    end
  end

  defp usage_until(ctx),
    do: unboxed(fn -> AdminRepo.get!(Runner, ctx.runner.id).usage_exhausted_until end)

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)
end
