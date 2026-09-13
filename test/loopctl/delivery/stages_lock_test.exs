defmodule Loopctl.Delivery.StagesLockTest do
  @moduledoc """
  Issue #803: the stage machine under GENUINE concurrency — separate database sessions, so
  the compare-and-set and the story share lock are what decide the outcome.

  A `Task.async` race inside `Ecto.Adapters.SQL.Sandbox` cannot test this: every allowed
  process shares one checked-out connection, which serialises the transactions on its own
  (see `progress/claim_lock_test.exs`). So these tests use `sandbox: false` sessions,
  commit their rows under a `fixture(:committed_tenant)`, run `async: false`, and sweep the
  committed tenants at module boundaries. Two tests DO append to the audit chain (the
  per-tenant chain lock is what they prove), and those rows would block the tenant delete —
  `purge_chain/1` removes them at the end of every test.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  # The test process holds one connection of the pool the racers share; the second is left
  # spare deliberately, so a slow runner has somewhere to go. Every other test in this
  # module runs at most two concurrent tasks against one pool, which fits any pool this
  # config produces (`test_concurrency * 2`, floor 2 schedulers).
  @reserved_connections 2
  @min_racers 2
  @max_racers 6
  @ownership_timeout :timer.seconds(60)

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
    with_chain_delete_trigger_disabled(fn ->
      AdminRepo.query!("DELETE FROM audit_chain WHERE tenant_id = $1", [
        Ecto.UUID.dump!(tenant_id)
      ])
    end)
  end

  # ONE transaction around all three statements: DDL is transactional in Postgres, so a
  # failing DELETE rolls the DISABLE back with it. Run as three autocommitted statements,
  # a failure in the middle leaves the audit chain's delete-blocking trigger OFF for the
  # rest of the run — and permanently, in a database every branch on this box shares.
  defp with_chain_delete_trigger_disabled(fun) do
    # `on_exit` runs in its own process (which must check out), the tests run in this one
    # (which already has).
    case Sandbox.checkout(AdminRepo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end

    {:ok, result} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!(
          "ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        result = fun.()

        AdminRepo.query!(
          "ALTER TABLE audit_chain ENABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        result
      end)

    result
  end

  defp chain_delete_trigger_enabled? do
    %{rows: [[tgenabled]]} =
      AdminRepo.query!(
        "SELECT tgenabled FROM pg_trigger WHERE tgname = 'audit_chain_prevent_delete_trigger'"
      )

    tgenabled == "O"
  end

  # Each `sandbox: false` task HOLDS a real connection of every repo it checks out for its
  # whole life, so a task checks out only the repos it uses: `Stages` is `Repo`, the
  # reclaimer, the raw row writes and `AuditChain.append/2` are `AdminRepo`. Checking out
  # both everywhere doubled the demand on a pool the CI runner has less headroom in than
  # this box (#821: "connection not available and request was dropped from queue").
  defp unboxed(repos, fun) do
    Task.async(fn ->
      Enum.each(repos, fn repo ->
        :ok = Sandbox.checkout(repo, sandbox: false, ownership_timeout: @ownership_timeout)
      end)

      fun.()
    end)
  end

  # How many racers the pool can actually serve. `config/test.exs` sizes each repo's pool
  # from the machine's scheduler count, so the number is READ, never assumed: the CI runner
  # is smaller and busier than a dev box, and a test that outruns the pool fails on a
  # checkout queue timeout instead of on the race it is testing. Two is the floor — a race
  # needs two — and the assertion is the same at any size: exactly one winner.
  defp racers do
    pool_size = Application.get_env(:loopctl, Repo)[:pool_size] || @min_racers

    pool_size
    |> Kernel.-(@reserved_connections)
    |> min(@max_racers)
    |> max(@min_racers)
  end

  test "concurrent advances from the same stage: exactly one wins", %{story: story} do
    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :implementing,
        claim_epoch: 1
      })

    n = racers()
    parent = self()

    tasks =
      for _ <- 1..n do
        unboxed([Repo], fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, claim_epoch: 1)
        end)
      end

    pids = for _ <- 1..n, do: receive(do: ({:ready, pid} -> pid))
    assert n >= @min_racers
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
      unboxed([AdminRepo], fn ->
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
      unboxed([Repo], fn ->
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

  test "the chain's delete-blocking trigger survives a failure while it is disabled" do
    assert chain_delete_trigger_enabled?()

    assert_raise RuntimeError, "boom", fn ->
      with_chain_delete_trigger_disabled(fn -> raise "boom" end)
    end

    # Left off, every later delete of an audit-chain row in this shared database would
    # silently succeed — including ones no test intended.
    assert chain_delete_trigger_enabled?()
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
      unboxed([AdminRepo], fn ->
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
      unboxed([Repo], fn ->
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
        unboxed([Repo], fn ->
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
        unboxed([AdminRepo], fn ->
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
               actor_lineage: [],
               effects: [merge_sha: String.duplicate("a", 40)]
             )

    assert {:error, :stale_claim_epoch} =
             Stages.record_effect(story.tenant_id, story.id, :pr_number, 7, claim_epoch: 1)

    assert AdminRepo.get!(StoryStage, row.id).stage == :queued
  end

  test "escalate retries ONCE when the runner moves the story under it", %{story: story} do
    # #824 round 2, finding 4. `Escalations.escalate/3` reads the stage row OUTSIDE the
    # transition, so a `stage` message landing in between makes its compare-and-set miss.
    # It used to answer 409 `stale_stage` and the escalation was LOST — neither the context
    # nor the MCP tool retries — even though escalating from the new stage is a valid edge.
    #
    # The interleaving is forced by a LOCK, not by timing. `Stages.advance/4` takes the story
    # `FOR SHARE` before it touches the stage row, so a session holding the story `FOR UPDATE`
    # parks the escalation at exactly the point after its read and before its
    # compare-and-set — which is the window the finding is about.
    agent = fixture(:stage_agent, %{tenant_id: story.tenant_id})

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(set: [assigned_agent_id: agent.id])

    row =
      fixture(:story_stage, %{
        repo: AdminRepo,
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: :implementing,
        claim_epoch: story.claim_epoch
      })

    blocker_ready = self()

    # The runner: hold the story, move the stage row, and commit only once the escalation is
    # demonstrably waiting behind us.
    blocker =
      unboxed([AdminRepo], fn ->
        AdminRepo.transaction(fn ->
          AdminRepo.one!(from s in Story, where: s.id == ^story.id, lock: "FOR UPDATE")
          send(blocker_ready, :holding)

          receive do
            :escalation_is_waiting -> :ok
          after
            @ownership_timeout -> flunk("the escalation never blocked on the story lock")
          end

          {1, _} =
            from(s in StoryStage, where: s.id == ^row.id)
            |> AdminRepo.update_all(set: [stage: :reviewing])
        end)
      end)

    assert_receive :holding, @ownership_timeout

    escalation =
      unboxed([Repo], fn ->
        Escalations.escalate(story.tenant_id, story.id,
          claim_epoch: story.claim_epoch,
          agent_id: agent.id,
          reason: "a human is needed",
          actor_lineage: []
        )
      end)

    # It has read `implementing` and is now parked on the story lock the blocker holds.
    assert waiting_on_story_lock?(story.id)
    send(blocker.pid, :escalation_is_waiting)
    Task.await(blocker, @ownership_timeout)

    # The retry escalates from `reviewing`, the stage the row ACTUALLY reached.
    assert {:ok, escalated} = Task.await(escalation, @ownership_timeout)
    assert escalated.stage == :escalated
    assert escalated.escalation_reason == "a human is needed"
    assert AdminRepo.get!(StoryStage, row.id).stage == :escalated
  end

  # A backend waiting on a lock for THIS story, which is what says the escalation reached its
  # transaction and parked — rather than a sleep, which would pass whether or not it had.
  defp waiting_on_story_lock?(story_id) do
    eventually(fn ->
      %{rows: [[waiting]]} =
        AdminRepo.query!(
          """
          SELECT count(*) FROM pg_locks blocked
            JOIN pg_stat_activity a ON a.pid = blocked.pid
           WHERE NOT blocked.granted
             AND a.query ILIKE '%stories%'
             AND a.wait_event_type = 'Lock'
          """,
          []
        )

      waiting > 0
    end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
