defmodule Loopctl.Delivery.MergePreconditionLockTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition` and `Loopctl.Delivery.MergeExecutor` against a lock
  ANOTHER database session holds (issue #803, US-45.5): the dispatch ledger locked while the
  gate reads the claim's route, and the stage row locked while the executor records `merged`.

  `async: false`, and COMMITTED, because a lock held by a second connection is the subject: a
  lock cannot be held against the connection that waits on it, and a second connection
  cannot see a sandbox transaction's rows. So the tenant is `fixture(:committed_tenant)`,
  every process runs on production's two connections (`Loopctl.Test.ProductionTopology`),
  and the tenant is swept after each test (`sweep_committed_tenants/1`) and every
  committed-runner tenant at the module boundaries. Everything else about the gate and the executor is
  `Loopctl.Delivery.MergePreconditionIntegrationTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures
  import Mox, only: [verify_on_exit!: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.MergeExecutor
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.MockMergeForge
  alias Loopctl.Repo
  alias Loopctl.Test.MergeForge
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story

  @head MergeForge.head()
  @tree MergeForge.tree()
  @base_head MergeForge.base_head()
  @merge MergeForge.merge()
  @session MergeForge.session()

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs, and several
    # dependencies resolve through Mox. Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first; from the
    # checkout on, every write of this process commits.
    # The sweep is registered before anything else can fail, so a setup that raises part-way
    # still leaves nothing behind.
    tenant = fixture(:committed_tenant, %{})
    on_exit(fn -> sweep_committed_tenants([tenant.id]) end)
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    fixture(:merge_ready_story, %{tenant_id: tenant.id, repo: MergeForge.repo(), head_sha: @head})
  end

  describe "thread mode (US-45.4)" do
    setup :thread_setup

    test "a route the ledger cannot answer is unevaluated with the mode UNKNOWN, never pr",
         ctx do
      test_pid = self()

      # A lock on the ledger held elsewhere: the route read waits out its lock_timeout and
      # answers :busy, so nothing is judged on a guessed route.
      holder =
        spawn(fn ->
          :ok = ProductionTopology.checkout_unboxed!([Repo])

          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE runner_dispatches IN ACCESS EXCLUSIVE MODE")
            send(test_pid, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held, 5_000
      on_exit(fn -> send(holder, :release) end)

      assert {:ok, %Verdict{decision: :unevaluated, mode: nil}} = evaluate(ctx)
      send(holder, :release)
    end
  end

  describe "merge executor (US-45.5)" do
    setup :thread_setup

    setup ctx do
      MergeForge.record_thread_allow(ctx, ctx.checkpoint, @head)
      story = AdminRepo.get!(Story, ctx.story_id)
      {:ok, route} = DispatchPayload.dispatch_route(ctx.tenant_id, story)
      {:ok, branch} = DispatchPayload.thread_branch(route, story, nil)
      MergeForge.stub_forge(branch)
      %{branch: branch}
    end

    test "round 2, finding 4: a transient failure writing merged retries, and the retry adopts it",
         ctx do
      test_pid = self()

      Mox.stub(MockMergeForge, :update_ref, fn @session, "master", @merge ->
        hold_stage_row(ctx, test_pid)
        :ok
      end)

      assert {:retry, {:merged_not_recorded, @merge, :busy}} =
               MergeExecutor.run(ctx.tenant_id, ctx.story_id)

      assert_receive :row_released, 10_000
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci

      MergeForge.stub_ancestors(%{{@merge, @base_head} => true})
      assert {:already_merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end
  end

  # The claim's thread-mode dispatch and first checkpoint (`fixture(:thread_claim)`), on a
  # runner of this committed tenant. `:committed_runner`, not `:runner`: enrolling appends a
  # `runner_enrolled` audit-chain entry. The fixture's own unboxed run checks this process's
  # Repo connection in on its way out, so the process takes it back.
  defp thread_setup(ctx) do
    {_raw_key, runner} = fixture(:committed_runner, %{tenant_id: ctx.tenant_id})
    :ok = ProductionTopology.checkout_unboxed!([Repo])
    MergeForge.stub_app_unreachable()

    fixture(:thread_claim, %{
      tenant_id: ctx.tenant_id,
      story_id: ctx.story_id,
      runner_id: runner.id,
      commit_sha: @head,
      tree_sha: @tree
    })
  end

  # Holds the story's stage row FOR UPDATE from another connection for longer than a stage
  # write waits, so the executor's `ci -> merged` meets real contention (`:busy`). Returns once
  # the lock is held; `:row_released` arrives when it is let go.
  defp hold_stage_row(ctx, test_pid) do
    parent = self()

    Task.start(fn ->
      :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

      AdminRepo.transaction(fn ->
        AdminRepo.query!("SELECT 1 FROM story_stages WHERE story_id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(ctx.story_id)
        ])

        send(parent, :row_held)
        Process.sleep(3_000)
      end)

      send(test_pid, :row_released)
    end)

    assert_receive :row_held, 5_000
  end

  defp evaluate(ctx), do: MergePrecondition.evaluate(ctx.tenant_id, ctx.story_id, opts())

  defp opts do
    [
      claim_epoch: 0,
      actor_label: "test",
      # Entering `escalated` is a CHAINED transition, and `Stages.advance/4` refuses one
      # that does not declare the actor's lineage. An operator key legitimately has none.
      actor_lineage: []
    ]
  end
end
