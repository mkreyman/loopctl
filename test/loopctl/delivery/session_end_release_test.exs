defmodule Loopctl.Delivery.SessionEndReleaseTest do
  @moduledoc """
  US-44.3: the `session_ended` reasons that END THE CLAIM — `crashed` and `usage_exhausted`,
  which re-queue the story, and the budget kills, which escalate it first — end to end through
  `Loopctl.Delivery.RunnerStages.end_session/4`.

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
  alias Loopctl.AuditChain
  alias Loopctl.BulkOperations
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Progress
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.WorkBreakdown.Queries
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

  defp ready_ids(ctx) do
    {:ok, %{data: stories}} =
      unboxed(fn -> Queries.list_ready_stories(ctx.tenant_id, page_size: 500) end)

    Enum.map(stories, & &1.id)
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

    test "the escalated story it leaves `pending` is neither listed as ready nor claimable",
         ctx do
      # The claim ended, so the story reads `pending` with nobody on it — exactly the shape of
      # a story that IS ready. What says it is not is the stage row, and both ways an agent
      # finds and takes work have to read it: the human it was escalated to must not be raced.
      assert {:ok, %{row: %{stage: :escalated}}} = end_session(ctx, "wall_clock_exceeded")
      assert story(ctx).agent_status == :pending

      refute ctx.story.id in ready_ids(ctx)

      assert {:error, :story_held} =
               unboxed(fn ->
                 Progress.contract_story(ctx.tenant_id, ctx.story.id, %{},
                   actor_label: "test",
                   skip_contract_check: true
                 )
               end)

      # A story that was already `contracted` is refused at the claim, single and bulk.
      unboxed(fn ->
        AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
          set: [agent_status: :contracted]
        )
      end)

      assert {:error, :story_held} =
               unboxed(fn ->
                 Progress.claim_story(ctx.tenant_id, ctx.story.id, agent_id: ctx.runner.agent_id)
               end)

      assert {:ok, [%{status: "error", reason: reason}]} =
               unboxed(fn ->
                 BulkOperations.bulk_claim(ctx.tenant_id, [ctx.story.id], ctx.runner.agent_id)
               end)

      assert reason =~ "story_held"
      assert story(ctx).agent_status == :contracted
      assert story(ctx).assigned_agent_id == nil
    end

    test "a crash's re-queued story stays ready: only `escalated` is held back", ctx do
      # The other side of the exclusion, so it cannot pass by hiding every released story.
      assert {:ok, %{row: %{stage: :queued}}} = end_session(ctx, "crashed")
      assert ctx.story.id in ready_ids(ctx)
    end

    test "an escalation whose lock is not free answers busy, and the resend lands it", ctx do
      # The tenant's hash-chain lock, held by another session: the escalation's chained entry
      # waits on it, its `lock_timeout` runs out, and `Stages.advance/4` answers `:busy`. That
      # is the ONE refusal of the escalation that is a retry — nothing landed but the record.
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            AdminRepo.transaction(fn ->
              AdminRepo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
                AuditChain.chain_lock_namespace(),
                ctx.tenant_id
              ])

              send(parent, :holding)

              receive do
                :release -> :ok
              end
            end)
          end)
        end)

      assert_receive :holding, 2_000

      try do
        assert {:error, :busy} = end_session(ctx, "wall_clock_exceeded")
      after
        send(holder.pid, :release)
        Task.await(holder, 5_000)
      end

      assert ledger(ctx).session_ended_reason == "wall_clock_exceeded"
      assert unboxed(fn -> Stages.get(ctx.tenant_id, ctx.story.id) end).stage == :implementing
      assert releases(ctx) == []

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")
      assert row.stage == :escalated
      assert length(releases(ctx)) == 1
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

      unboxed(fn ->
        DispatchLedger.record_session_end(ctx.tenant_id, ctx.runner.id, message, %{
          reason: reason,
          digest: TriageVerdictRecord.digest(message),
          counts_toward_retry_ceiling: Map.get(%{"crashed" => true}, reason),
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

  # A TENANT CHAIN THAT REFUSES APPENDS AS A HASH VIOLATION. The chain's own invariant trigger
  # cannot be driven to that state through the application — every append reads the head it
  # links to under the chain lock — so a trigger raising exactly what it raises, P0001
  # `audit_chain_hash_violation`, is installed for THIS tenant only (`WHEN` on `tenant_id`),
  # committed, and dropped by `repair_chain/1` or at exit. Committed DDL is why this lives in an
  # `async: false` module.
  defp break_chain(ctx, text \\ "audit_chain_hash_violation: injected by test") do
    name = chain_trigger(ctx)

    unboxed(fn ->
      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '#{text}' USING ERRCODE = 'P0001';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE INSERT ON audit_chain FOR EACH ROW
      WHEN (NEW.tenant_id = '#{ctx.tenant_id}') EXECUTE FUNCTION #{name}()
      """)
    end)

    on_exit(fn -> repair_chain(ctx) end)
  end

  defp repair_chain(ctx) do
    name = chain_trigger(ctx)

    unboxed(fn ->
      AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")
      AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end)
  end

  defp chain_trigger(ctx), do: "test_broken_chain_" <> String.replace(ctx.tenant_id, "-", "")

  defp stage_row(ctx), do: unboxed(fn -> Stages.get(ctx.tenant_id, ctx.story.id) end)

  describe "a broken chain at the runner-message boundary" do
    @describetag :capture_log

    test "a budget kill's escalation is answered audit_chain_append_failed, not raised", ctx do
      break_chain(ctx)

      assert {:error, :audit_chain_append_failed} = end_session(ctx, "wall_clock_exceeded")

      # The report is recorded; the escalation and the claim's end are not.
      assert ledger(ctx).session_ended_reason == "wall_clock_exceeded"
      assert stage_row(ctx).stage == :implementing
      assert story(ctx).claim_epoch == ctx.story.claim_epoch
      assert releases(ctx) == []
    end

    test "a stage message's chained transition is answered audit_chain_append_failed", ctx do
      break_chain(ctx)

      assert {:error, :audit_chain_append_failed} =
               unboxed(fn ->
                 RunnerStages.apply(ctx.tenant_id, ctx.runner.id, %{
                   dispatch_id: ctx.record.dispatch_id,
                   claim_epoch: ctx.record.claim_epoch,
                   from: :implementing,
                   to: :escalated,
                   edge: :session_escalated,
                   reason: "the session asked for a human",
                   effects: %{}
                 })
               end)

      assert stage_row(ctx).stage == :implementing
    end

    test "any OTHER database error still raises: the rescue names one condition", ctx do
      break_chain(ctx, "some_other_fault: injected by test")

      assert_raise Postgrex.Error, ~r/some_other_fault/, fn ->
        end_session(ctx, "wall_clock_exceeded")
      end
    end
  end

  describe "the lease reclaim re-drives a budget kill" do
    @describetag :capture_log

    defp expire_lease(ctx) do
      unboxed(fn ->
        AdminRepo.update_all(from(s in Story, where: s.id == ^ctx.story.id),
          set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)]
        )
      end)
    end

    defp reclaim(ctx) do
      unboxed(fn ->
        Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)
      end)
    end

    defp reclaim_entries(ctx, action) do
      unboxed(fn ->
        AdminRepo.all(
          from a in AuditLog,
            where: a.tenant_id == ^ctx.tenant_id and a.entity_id == ^ctx.story.id,
            where: a.action == ^action
        )
      end)
    end

    test "escalates instead of re-queueing, then ends the claim as the session end", ctx do
      # The channel's escalation did not land (the chain refused it); the lease then ran out.
      break_chain(ctx)
      assert {:error, :audit_chain_append_failed} = end_session(ctx, "max_turns_exceeded")
      repair_chain(ctx)
      expire_lease(ctx)

      assert {:ok, released} = reclaim(ctx)

      assert released.agent_status == :pending
      assert released.claim_epoch == ctx.story.claim_epoch + 1

      # NEVER re-queued: escalated over the budget edge, and the release only rebinds it.
      row = stage_row(ctx)
      assert row.stage == :escalated
      assert row.claim_epoch == released.claim_epoch
      assert requeues(ctx) == [{"implementing", "escalated", "budget_reported"}]
      refute ctx.story.id in ready_ids(ctx)

      # Audited as the session end it was, by the worker that ran it — not a lease expiry.
      assert [%AuditLog{actor_type: "system", actor_label: label, new_state: new_state}] =
               releases(ctx)

      assert label == "worker:reclaim_expired_claims"
      assert new_state["session_ended_reason"] == "max_turns_exceeded"
      assert reclaim_entries(ctx, "claim_lease_expired") == []

      # The escalation's transition gave the session's slot back.
      assert runner_in_flight(ctx) == 0
    end

    test "leaves the claim HELD while the chain still refuses, and lands after the repair",
         ctx do
      break_chain(ctx)
      assert {:error, :audit_chain_append_failed} = end_session(ctx, "wall_clock_exceeded")
      expire_lease(ctx)

      assert {:error, :budget_escalation_refused} = reclaim(ctx)

      held = story(ctx)
      assert held.agent_status in [:assigned, :implementing]
      assert held.claim_epoch == ctx.story.claim_epoch
      assert stage_row(ctx).stage == :implementing
      assert releases(ctx) == []
      assert reclaim_entries(ctx, "claim_lease_expired") == []

      # The next sweep, after an operator repaired the chain.
      repair_chain(ctx)
      assert {:ok, _released} = reclaim(ctx)
      assert stage_row(ctx).stage == :escalated
      assert length(releases(ctx)) == 1
    end

    test "a budget kill recorded under an EARLIER claim does not touch a later one", ctx do
      # The report is about the claim its dispatch served. Once that claim has ended and a new
      # one has started, the new claim's expired lease is an ordinary lease expiry.
      assert {:ok, {:recorded, _session}} = record_only(ctx, "wall_clock_exceeded")

      later =
        unboxed(fn ->
          {:ok, _} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id)

          {:ok, _} =
            Progress.contract_story(ctx.tenant_id, ctx.story.id, %{}, skip_contract_check: true)

          {:ok, later} =
            Progress.claim_story(ctx.tenant_id, ctx.story.id, agent_id: ctx.runner.agent_id)

          later
        end)

      expire_lease(ctx)

      assert {:ok, _released} =
               unboxed(fn ->
                 Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, later.claim_epoch)
               end)

      assert [_expiry] = reclaim_entries(ctx, "claim_lease_expired")
      assert releases(ctx) == []
    end

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
end
