defmodule Loopctl.Delivery.StagesLockTest do
  @moduledoc """
  Issue #803: the stage machine under GENUINE concurrency — separate database sessions, so
  the compare-and-set and the story share lock are what decide the outcome.

  A `Task.async` race inside `Ecto.Adapters.SQL.Sandbox` cannot test this: every allowed
  process shares one checked-out connection, which serialises the transactions on its own
  (see `progress/claim_lock_test.exs`). So these tests use `sandbox: false` sessions,
  commit their rows under a `fixture(:committed_tenant)`, run `async: false`, and sweep the
  committed tenants at module boundaries. Nothing here appends to the audit chain, whose
  rows would block the tenant delete.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs, and
    # `Progress.claim_story/3` mints a capability through MockSecrets. Global mode because
    # the claim runs in a Task; safe here since the module is async: false.
    Mox.set_mox_global()
    Mox.stub(Loopctl.MockSecrets, :get, fn _name -> {:error, :not_found} end)

    # `fixture(:committed_tenant)` runs its own unboxed AdminRepo checkout, so it goes first.
    tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: 1})

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(set: [agent_status: :assigned])

    on_exit(fn -> purge_chain(tenant.id) end)

    %{tenant: tenant, story: %{story | agent_status: :assigned}}
  end

  # `audit_chain` rows have a tenant FK with ON DELETE NOTHING and a delete-BLOCKING
  # trigger, so a tenant that appended anything cannot be swept at module exit. These rows
  # are this module's own committed test data; the trigger is disabled for the one delete
  # and restored immediately. Safe because ExUnit runs `async: false` modules alone.
  defp purge_chain(tenant_id) do
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    AdminRepo.query!("ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger")

    AdminRepo.query!("DELETE FROM audit_chain WHERE tenant_id = $1", [
      Ecto.UUID.dump!(tenant_id)
    ])

    AdminRepo.query!("ALTER TABLE audit_chain ENABLE TRIGGER audit_chain_prevent_delete_trigger")
  end

  defp unboxed(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      :ok = Sandbox.checkout(AdminRepo, sandbox: false)
      fun.()
    end)
  end

  test "concurrent advances from the same stage: exactly one wins", %{story: story} do
    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :implementing,
        claim_epoch: 1
      })

    n = 6
    parent = self()

    tasks =
      for _ <- 1..n do
        unboxed(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, claim_epoch: 1)
        end)
      end

    pids = for _ <- 1..n, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Task.await_many(tasks, 15_000)

    assert Enum.count(results, &match?({:ok, %StoryStage{stage: :reviewing}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :stale_stage}, &1)) == n - 1

    final = AdminRepo.get!(StoryStage, row.id)
    assert final.lock_version == row.lock_version + 1

    assert AdminRepo.aggregate(from(e in StageEvent, where: e.story_stage_id == ^row.id), :count) ==
             1
  end

  test "a release committing while an advance runs wins: the advance waits on the story and refuses",
       %{story: story} do
    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :implementing,
        claim_epoch: 1
      })

    parent = self()

    # A release in flight: the story's epoch is bumped but not committed. Without the FOR
    # SHARE lock the advance reads the last COMMITTED epoch (1), matches, and moves the row.
    releaser =
      unboxed(fn ->
        AdminRepo.transaction(fn ->
          {1, _} =
            from(s in Story, where: s.id == ^story.id)
            |> AdminRepo.update_all(set: [claim_epoch: 2])

          send(parent, :releasing)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :releasing, 2_000

    advancer =
      unboxed(fn ->
        Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, claim_epoch: 1)
      end)

    Process.sleep(200)
    send(releaser.pid, :commit)
    Task.await(releaser, 5_000)

    assert {:error, :stale_claim_epoch} = Task.await(advancer, 5_000)
    assert AdminRepo.get!(StoryStage, row.id).stage == :implementing
  end

  test "a row rebound by a claim is advanceable again under the claim's epoch", %{
    tenant: tenant,
    story: story
  } do
    # Committed on both connections, so the RLS repo `Stages.advance/4` uses and the
    # AdminRepo `claim_story/3` uses see the same rows — the end-to-end shape the
    # sandboxed test in `stages_test.exs` cannot reach.
    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :triaged,
      claim_epoch: 1
    })

    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(set: [agent_status: :contracted])

    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)
    assert claimed.claim_epoch == 2

    assert {:ok, %StoryStage{stage: :queued}} =
             Stages.advance(tenant.id, story.id, {:triaged, :queued}, claim_epoch: 2)
  end

  test "a chained transition waits on the tenant's chain lock", %{tenant: tenant, story: story} do
    # Without the advisory lock two appends in one tenant read the same head under their own
    # snapshots, compute the same chain_position and the chain trigger raises on the second.
    # Here the lock is HELD by another session, so the transition must block on it.
    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :queued,
      claim_epoch: 1
    })

    parent = self()

    holder =
      unboxed(fn ->
        AdminRepo.transaction(fn ->
          AdminRepo.query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2))", [
            AuditChain.chain_lock_namespace(),
            tenant.id
          ])

          send(parent, :holding)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :holding, 2_000

    advancer =
      unboxed(fn ->
        started = System.monotonic_time(:millisecond)

        result =
          Stages.advance(tenant.id, story.id, {:queued, :claimed},
            claim_epoch: 1,
            actor_lineage: []
          )

        {result, System.monotonic_time(:millisecond) - started}
      end)

    Process.sleep(300)
    send(holder.pid, :release)
    Task.await(holder, 5_000)

    assert {{:ok, %StoryStage{stage: :claimed}}, elapsed_ms} = Task.await(advancer, 10_000)
    assert elapsed_ms >= 250
  end

  test "two chained transitions in one tenant both commit, with gapless chain positions", %{
    tenant: tenant,
    story: first
  } do
    second = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: 1})

    {2, _} =
      from(s in Story, where: s.id in ^[first.id, second.id])
      |> AdminRepo.update_all(set: [agent_status: :assigned])

    for story <- [first, second] do
      fixture(:story_stage, %{
        tenant_id: tenant.id,
        story_id: story.id,
        stage: :queued,
        claim_epoch: 1
      })
    end

    parent = self()

    tasks =
      for story <- [first, second] do
        unboxed(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          Stages.advance(tenant.id, story.id, {:queued, :claimed},
            claim_epoch: 1,
            actor_lineage: []
          )
        end)
      end

    pids = for _ <- 1..2, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, %StoryStage{stage: :claimed}}, &1)), inspect(results)

    positions =
      AdminRepo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant.id,
          order_by: [asc: e.chain_position],
          select: e.chain_position
      )

    assert positions == [0, 1]
  end

  test "two AuditChain.append/2 calls in one tenant both commit, gapless", %{tenant: tenant} do
    # The other append path (AdminRepo, no stage machine) takes the same per-tenant lock.
    parent = self()

    tasks =
      for n <- 1..2 do
        unboxed(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          AuditChain.append(tenant.id, %{
            action: "test_concurrent_append",
            actor_lineage: [],
            entity_type: "story",
            entity_id: nil,
            payload: %{"n" => n}
          })
        end)
      end

    pids = for _ <- 1..2, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, %Entry{}}, &1)), inspect(results)

    assert AdminRepo.all(
             from e in Entry,
               where: e.tenant_id == ^tenant.id,
               order_by: [asc: e.chain_position],
               select: e.chain_position
           ) == [0, 1]
  end

  test "a zombie runner is fenced after the reclaimer requeues its story", %{story: story} do
    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :ci,
        claim_epoch: 1
      })

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])

    assert {:ok, released} = Progress.reclaim_expired_claim(story.tenant_id, story.id, 1)
    assert released.claim_epoch == 2

    requeued = AdminRepo.get!(StoryStage, row.id)
    assert {requeued.stage, requeued.claim_epoch} == {:queued, 2}
    assert requeued.attempts == %{"runner_lost" => 1}

    # The runner that held epoch 1 comes back and tries to carry on.
    assert {:error, :stale_claim_epoch} =
             Stages.advance(story.tenant_id, story.id, {:ci, :merged},
               claim_epoch: 1,
               actor_lineage: []
             )

    assert {:error, :stale_claim_epoch} =
             Stages.record_effect(story.tenant_id, story.id, :pr_number, 7, claim_epoch: 1)

    assert AdminRepo.get!(StoryStage, row.id).stage == :queued
  end
end
