defmodule Loopctl.Delivery.SessionEndReleaseFaultTest do
  @moduledoc """
  US-44.3: the claim-ending `session_ended` reasons through
  `Loopctl.Delivery.RunnerStages.end_session/4` and the lease reclaim, when the escalation
  CANNOT land: the tenant's chain lock held by another session, and a chain or a runner row
  that refuses the write.

  `async: false`, and COMMITTED, because each subject needs a second connection or DDL on a
  shared table. The chain lock is an advisory lock another session holds, which cannot be held
  against the connection that waits on it; the refusals are triggers on `audit_chain` and
  `runners`, and DDL on a shared table holds its lock until the transaction ends, so inside an
  async test's sandbox transaction it would stall every other test writing those tables. So
  the rows are committed (`fixture(:committed_tenant)` and its siblings, then production's two
  connections, `Loopctl.Test.ProductionTopology`), every trigger is dropped on exit, and
  `sweep_committed_runner_tenants/0` removes the rows, chain entries included. Everything else
  is `Loopctl.Delivery.SessionEndReleaseTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Loopctl.Fixtures
  import Mox, only: [verify_on_exit!: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.Runner
  alias Loopctl.Test.ProductionTopology
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
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # The committed fixtures run their own unboxed checkout, so they go first; from the
    # checkout on, every write of this process commits.
    tenant = fixture(:committed_tenant, %{})
    {_raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "minis"})
    story = fixture(:committed_story, %{tenant_id: tenant.id})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

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

  describe "a budget kill (AC-44.3.3)" do
    test "an escalation whose lock is not free answers busy, and the resend lands it", ctx do
      # The tenant's hash-chain lock, held by another session: the escalation's chained entry
      # waits on it, its `lock_timeout` runs out, and `Stages.advance/4` answers `:busy`. That
      # is the ONE refusal of the escalation that is a retry — nothing landed but the record.
      parent = self()

      holder =
        Task.async(fn ->
          # Its own connection, as in production: the setting is per process.
          :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

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

      assert_receive :holding, 2_000

      try do
        assert {:error, :busy} = end_session(ctx, "wall_clock_exceeded")
      after
        send(holder.pid, :release)
        Task.await(holder, 5_000)
      end

      assert ledger(ctx).session_ended_reason == "wall_clock_exceeded"
      assert Stages.get(ctx.tenant_id, ctx.story.id).stage == :implementing
      assert releases(ctx) == []

      assert {:ok, %{row: row, replayed?: true}} = end_session(ctx, "wall_clock_exceeded")
      assert row.stage == :escalated
      assert length(releases(ctx)) == 1
    end
  end

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
               RunnerStages.apply(ctx.tenant_id, ctx.runner.id, %{
                 dispatch_id: ctx.record.dispatch_id,
                 claim_epoch: ctx.record.claim_epoch,
                 from: :implementing,
                 to: :escalated,
                 edge: :session_escalated,
                 reason: "the session asked for a human",
                 effects: %{}
               })

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

    test "a recorded usage_exhausted whose hold the database refuses is reclaimed COUNTED",
         ctx do
      assert {:ok, {:recorded, _session}} = record_only(ctx, "usage_exhausted")
      name = "test_hold_refused_" <> String.replace(ctx.runner.id, "-", "")

      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'refused by test' USING ERRCODE = '22023';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE UPDATE ON runners FOR EACH ROW
      WHEN (NEW.id = '#{ctx.runner.id}' AND
            NEW.usage_exhausted_until IS DISTINCT FROM OLD.usage_exhausted_until)
      EXECUTE FUNCTION #{name}()
      """)

      on_exit(fn ->
        :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON runners")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      expire_lease(ctx)
      assert {:ok, _released} = reclaim(ctx)
      assert stage_row(ctx).attempts == %{"runner_lost" => 1}
      assert usage_until(ctx) == nil
    end
  end

  # A TENANT CHAIN THAT REFUSES APPENDS AS A HASH VIOLATION. The chain's own invariant trigger
  # cannot be driven to that state through the application — every append reads the head it
  # links to under the chain lock — so a trigger raising exactly what it raises, P0001
  # `audit_chain_hash_violation`, is installed for THIS tenant only (`WHEN` on `tenant_id`),
  # committed, and dropped by `repair_chain/1` or at exit.
  defp break_chain(ctx, text \\ "audit_chain_hash_violation: injected by test") do
    name = chain_trigger(ctx)

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

    on_exit(fn -> repair_chain(ctx) end)
  end

  # Called from the test process and from an `on_exit`, which runs in a process of its own and
  # so needs its own checkout.
  defp repair_chain(ctx) do
    name = chain_trigger(ctx)
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

    AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")
    AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
  end

  defp chain_trigger(ctx), do: "test_broken_chain_" <> String.replace(ctx.tenant_id, "-", "")

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

  defp stage_row(ctx), do: Stages.get(ctx.tenant_id, ctx.story.id)

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

  defp usage_until(ctx),
    do: AdminRepo.get!(Runner, ctx.runner.id).usage_exhausted_until
end
