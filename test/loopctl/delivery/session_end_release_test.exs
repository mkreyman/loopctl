defmodule Loopctl.Delivery.SessionEndReleaseTest do
  @moduledoc """
  US-44.3: the `session_ended` reasons that END THE CLAIM — `crashed` and `usage_exhausted`,
  which re-queue the story, and the budget kills, which escalate it first — end to end through
  `Loopctl.Delivery.RunnerStages.end_session/4`.

  The path spans BOTH repos: the report is recorded on the dispatch ledger (the RLS
  `Loopctl.Repo`) and the release is an `AdminRepo` transaction. AdminRepo runs on Repo's
  sandbox connection in test (`Loopctl.AdminRepo.Route`), so both see this test's own rows and
  nothing here commits. The tests whose subject needs a second connection (a chain lock held
  by another session, a refusal injected with DDL) are
  `Loopctl.Delivery.SessionEndReleaseFaultTest`. The Repo-only reasons and every refusal are
  in `Loopctl.Delivery.SessionEndTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.BulkOperations
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
  alias Loopctl.WorkBreakdown.Queries
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  # A story claimed by the runner's own agent with a full 24h lease — 23h and more still to
  # run, so only the report can release it — its stage row at `implementing` under that claim,
  # and an ACCEPTED implement dispatch holding one slot on the runner.
  setup do
    tenant = fixture(:tenant, %{trust_tier: :agent_rooted})
    {_raw, runner} = fixture(:runner, %{tenant_id: tenant.id, name: "minis"})
    story = fixture(:ledger_story, %{tenant_id: tenant.id})

    {:ok, story} =
      Progress.contract_story(tenant.id, story.id, %{},
        actor_label: "test",
        skip_contract_check: true
      )

    {:ok, story} = Progress.claim_story(tenant.id, story.id, agent_id: runner.agent_id)

    fixture(:story_stage, %{
      repo: AdminRepo,
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :implementing,
      claim_epoch: story.claim_epoch
    })

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: tenant.id,
        runner: runner,
        story_id: story.id,
        claim_epoch: story.claim_epoch
      })

    %{tenant_id: tenant.id, runner: runner, story: story, record: record}
  end

  defp end_session(ctx, reason) do
    RunnerStages.end_session(
      ctx.tenant_id,
      ctx.runner.id,
      %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        reason: reason
      },
      actor_id: ctx.runner.api_key_id
    )
  end

  defp story(ctx), do: AdminRepo.get!(Story, ctx.story.id)

  defp runner_in_flight(ctx),
    do: AdminRepo.get!(Runner, ctx.runner.id).in_flight

  defp ledger(ctx), do: AdminRepo.get!(DispatchRecord, ctx.record.id)

  defp releases(ctx) do
    AdminRepo.all(
      from a in AuditLog,
        where: a.tenant_id == ^ctx.tenant_id and a.entity_id == ^ctx.story.id,
        where: a.action == "claim_session_ended"
    )
  end

  defp ready_ids(ctx) do
    {:ok, %{data: stories}} =
      Queries.list_ready_stories(ctx.tenant_id, page_size: 500)

    Enum.map(stories, & &1.id)
  end

  defp requeues(ctx) do
    AdminRepo.all(
      from e in StageEvent,
        where: e.tenant_id == ^ctx.tenant_id and e.story_id == ^ctx.story.id,
        where: e.event == "transitioned",
        select: {e.from_stage, e.to_stage, e.edge}
    )
  end

  test "crashed releases the claim before the lease runs out, over runner_lost (AC-44.3.4)",
       ctx do
    assert DateTime.diff(ctx.story.claimed_until, DateTime.utc_now(), :hour) >= 23
    assert runner_in_flight(ctx) == 1

    assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "crashed")

    released = story(ctx)
    # Released and, under the retry ceiling, re-contracted for the driver (US-44.4).
    assert released.agent_status == :contracted
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
    # Spent nothing, so re-contracted whatever the ceiling (US-44.4).
    assert story(ctx).agent_status == :contracted
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
    {:ok, _} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id)
    after_unclaim = story(ctx)

    assert {:error, :stale_claim_epoch} = end_session(ctx, "crashed")

    assert story(ctx).claim_epoch == after_unclaim.claim_epoch
    assert releases(ctx) == []
    assert ledger(ctx).session_ended_reason == nil
    # Where the OPERATOR'S release put it — escalated over `operator_released` (US-44.4) — and
    # not somewhere the refused report moved it.
    assert Stages.get(ctx.tenant_id, ctx.story.id).stage == :escalated
  end

  # AC-44.4.4 for a COUNTED US-44.3 release: the crash that reaches the retry ceiling
  # (`config/test.exs` sets 2) escalates instead of re-queuing, and the ack says so.
  test "a crash that reaches the retry ceiling escalates over attempts_exhausted", ctx do
    {1, _} =
      from(s in Loopctl.Delivery.StoryStage,
        where: s.tenant_id == ^ctx.tenant_id and s.story_id == ^ctx.story.id
      )
      |> AdminRepo.update_all(set: [attempts: %{"runner_lost" => 1}])

    assert {:ok, %{row: row, replayed?: false}} = end_session(ctx, "crashed")

    assert row.stage == :escalated
    assert row.attempts["runner_lost"] == 2
    assert row.escalation_reason =~ "attempts_exhausted: 2 counted releases"
    assert story(ctx).agent_status == :pending
    assert runner_in_flight(ctx) == 0
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

    test "the escalated story it leaves `pending` is neither listed as ready nor claimable",
         ctx do
      # The claim ended, so the story reads `pending` with nobody on it — exactly the shape of
      # a story that IS ready. What says it is not is the stage row, and both ways an agent
      # finds and takes work have to read it: the human it was escalated to must not be raced.
      assert {:ok, %{row: %{stage: :escalated}}} = end_session(ctx, "wall_clock_exceeded")
      assert story(ctx).agent_status == :pending

      refute ctx.story.id in ready_ids(ctx)

      assert {:error, :story_held} =
               Progress.contract_story(ctx.tenant_id, ctx.story.id, %{},
                 actor_label: "test",
                 skip_contract_check: true
               )

      # A story that was already `contracted` is refused at the claim, single and bulk.
      AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
        set: [agent_status: :contracted]
      )

      assert {:error, :story_held} =
               Progress.claim_story(ctx.tenant_id, ctx.story.id, agent_id: ctx.runner.agent_id)

      assert {:ok, [%{status: "error", reason: reason}]} =
               BulkOperations.bulk_claim(ctx.tenant_id, [ctx.story.id], ctx.runner.agent_id)

      assert reason =~ "story_held"
      assert story(ctx).agent_status == :contracted
      assert story(ctx).assigned_agent_id == nil
    end

    test "a crash's re-queued story stays placeable: only `escalated` is held back", ctx do
      # The other side of the exclusion, so it cannot pass by hiding every released story. A
      # re-queued delivery story is re-contracted in the release (US-44.4), so "placeable" is
      # contracted and outside the held set, not listed as a `pending` ready story.
      assert {:ok, %{row: %{stage: :queued}}} = end_session(ctx, "crashed")
      assert story(ctx).agent_status == :contracted

      refute MapSet.member?(
               Stages.held_story_ids(ctx.tenant_id, [ctx.story.id]),
               ctx.story.id
             )
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
    # release never ran. Written here the way `end_session/4` writes it, so the resend meets
    # exactly the record its first copy would have left.
    defp record_only(ctx, reason) do
      message = %{
        dispatch_id: ctx.record.dispatch_id,
        claim_epoch: ctx.record.claim_epoch,
        reason: reason
      }

      DispatchLedger.record_session_end(ctx.tenant_id, ctx.runner.id, message, %{
        reason: reason,
        digest: TriageVerdictRecord.digest(message),
        counts_toward_retry_ceiling:
          Map.get(%{"crashed" => true, "usage_exhausted" => false}, reason),
        story_id: ctx.story.id
      })
    end

    test "a recorded crash whose release never ran is released by the resend", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "crashed")
      assert story(ctx).agent_status in [:assigned, :implementing]

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "crashed")

      assert row.stage == :queued
      assert story(ctx).agent_status == :contracted
      assert length(releases(ctx)) == 1
      assert runner_in_flight(ctx) == 0
    end

    test "a recorded budget kill that escalated nothing is escalated and ended by the resend",
         ctx do
      # What an escalation that did not land leaves: the report on the ledger, the row still
      # in flight, the claim still held. The resend is the only way the work completes, which
      # is why a lock that was not free is answered as a retry.
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

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")

      assert row.stage == :escalated
      assert row.attempts == %{"budget_reported" => 1}
      assert story(ctx).agent_status == :pending
      assert length(releases(ctx)) == 1
    end

    test "and never releases a claim that ended some other way in between", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "crashed")
      {:ok, _} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id)
      after_unclaim = story(ctx)

      assert {:ok, %{replayed?: true}} = end_session(ctx, "crashed")

      assert story(ctx).claim_epoch == after_unclaim.claim_epoch
      assert releases(ctx) == []
      # That claim ended, so the session's slot is free either way.
      assert runner_in_flight(ctx) == 0
    end
  end

  defp stage_row(ctx), do: Stages.get(ctx.tenant_id, ctx.story.id)

  describe "the lease reclaim re-drives a budget kill" do
    @describetag :capture_log

    defp expire_lease(ctx) do
      AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
        set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )
    end

    defp reclaim(ctx) do
      Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)
    end

    defp reclaim_entries(ctx, action) do
      AdminRepo.all(
        from a in AuditLog,
          where: a.tenant_id == ^ctx.tenant_id and a.entity_id == ^ctx.story.id,
          where: a.action == ^action
      )
    end

    test "a budget kill recorded under an EARLIER claim does not touch a later one", ctx do
      # The report is about the claim its dispatch served. Once that claim has ended and a new
      # one has started, the new claim's expired lease is an ordinary lease expiry.
      assert {:ok, {:recorded, _session}} = record_only(ctx, "wall_clock_exceeded")

      # A release that leaves the row placeable (US-44.4): an operator's own force-unclaim
      # escalates it, which would hold the story rather than let a later claim start.
      {:ok, _} =
        Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id,
          release_cause: :placement_refused
        )

      {:ok, later} =
        Progress.claim_story(ctx.tenant_id, ctx.story.id, agent_id: ctx.runner.agent_id)

      expire_lease(ctx)

      assert {:ok, _released} =
               Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, later.claim_epoch)

      assert [_expiry] = reclaim_entries(ctx, "claim_lease_expired")
      assert releases(ctx) == []
    end

    # #884 review round 2, finding 2. The report was recorded and the node died before the
    # hold and the release ran. The reclaim finishes that session end: the machine held out,
    # the claim released WITHOUT spending an attempt.
    test "a recorded usage_exhausted is finished by the reclaim: held out, uncounted", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "usage_exhausted")
      expire_lease(ctx)

      assert {:ok, _released} = reclaim(ctx)

      row = stage_row(ctx)
      assert row.stage == :queued
      assert row.attempts == %{}
      assert %DateTime{} = usage_until(ctx)

      assert [%AuditLog{new_state: %{"session_ended_reason" => "usage_exhausted"}}] =
               releases(ctx)
    end

    # #884 review round 3, finding 7. A hold already in place — here the runner's own precise
    # reset, two hours out — is not rewritten to the provisional eight days, and a sweep that
    # retries does not keep pushing it forward.
    test "a runner already held out keeps its own hold when the reclaim finishes", ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "usage_exhausted")
      resets_at = DateTime.add(DateTime.utc_now(), 7_200, :second)

      :ok = Usage.record(ctx.tenant_id, ctx.runner.id, %{exhausted: true, resets_at: resets_at})

      expire_lease(ctx)
      assert {:ok, _released} = reclaim(ctx)

      assert stage_row(ctx).attempts == %{}
      assert_in_delta seconds_from_now(usage_until(ctx)), 7_200, 5
    end

    # With the machine NOT held out, the counted expiry is the only bound on the story being
    # placed straight back on it (#883 review round 2, finding 1).
    test "a claim whose session CRASHED is still re-queued as a lease expiry", ctx do
      # Only a BUDGET reason is re-driven; a recorded crash whose release never ran is an
      # ordinary expired lease.
      assert {:ok, {:recorded, _session}} = record_only(ctx, "crashed")
      expire_lease(ctx)

      assert {:ok, _released} = reclaim(ctx)
      assert stage_row(ctx).stage == :queued
      assert [_expiry] = reclaim_entries(ctx, "claim_lease_expired")
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
      assert Runners.usage_exhausted?(ctx.tenant_id, ctx.runner.id)

      {1, _} =
        AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
          set: [trust_tier: :human_anchored]
        )

      {_raw, operator} = fixture(:api_key, %{tenant_id: ctx.tenant_id, role: :user})

      assert {:error, :runner_exhausted} =
               Placement.place(
                 ctx.tenant_id,
                 ctx.runner.id,
                 %{"dispatch_id" => Ecto.UUID.generate(), "story_id" => ctx.story.id},
                 api_key: operator,
                 actor_label: "test"
               )
    end

    test "a crash does not mark the runner: the machine is fine, the session was not", ctx do
      assert {:ok, _} = end_session(ctx, "crashed")
      assert usage_until(ctx) == nil
    end

    test "a resend after the account was reported refilled does NOT re-exhaust it", ctx do
      assert {:ok, %{replayed?: false}} = end_session(ctx, "usage_exhausted")

      assert :ok =
               Usage.record(ctx.tenant_id, ctx.runner.id, %{exhausted: false})

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
      {_raw, peer} = fixture(:runner, %{tenant_id: ctx.tenant_id, name: "beelink"})

      :ok = Usage.record(ctx.tenant_id, ctx.runner.id, %{exhausted: true, account_ref: "a"})
      :ok = Usage.record(ctx.tenant_id, peer.id, %{exhausted: false, account_ref: "a"})

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
    do: AdminRepo.get!(Runner, ctx.runner.id).usage_exhausted_until

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)
end
