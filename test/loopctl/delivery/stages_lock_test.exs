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
    # `fixture(:committed_tenant)` runs its own unboxed AdminRepo checkout, so it goes first.
    tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: 1})

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(set: [agent_status: :assigned])

    %{tenant: tenant, story: %{story | agent_status: :assigned}}
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
             Stages.advance(story.tenant_id, story.id, {:ci, :merged}, claim_epoch: 1)

    assert {:error, :stale_claim_epoch} =
             Stages.record_effect(story.tenant_id, story.id, :pr_number, 7, claim_epoch: 1)

    assert AdminRepo.get!(StoryStage, row.id).stage == :queued
  end
end
