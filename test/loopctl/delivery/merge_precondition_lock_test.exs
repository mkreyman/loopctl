defmodule Loopctl.Delivery.MergePreconditionLockTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition` and `Loopctl.Delivery.MergeExecutor` against a lock
  ANOTHER database session holds (issue #803, US-45.5): the dispatch ledger locked while the
  gate reads the claim's route, and the stage row locked while the executor records `merged`.

  `async: false`, and COMMITTED, because a lock held by a second connection is the subject: a
  lock cannot be held against the connection that waits on it, and a second connection
  cannot see a sandbox transaction's rows. So the tenant is `fixture(:committed_tenant)`,
  every process runs on production's two connections (`Loopctl.Test.ProductionTopology`),
  and the tenant and the rows that block its delete are purged after each test and at the
  module boundaries. Everything else about the gate and the executor is
  `Loopctl.Delivery.MergePreconditionIntegrationTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Delivery.MergeExecutor
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.MockMergeForge
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.WorkBreakdown.Story

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @tree String.duplicate("e", 40)
  @base_tree String.duplicate("f", 40)
  @base_head String.duplicate("8", 40)
  @merge String.duplicate("c", 40)
  @session %{repo: @repo, token: "ghs_test"}

  setup_all do
    full_sweep()
    on_exit(&full_sweep/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs, and several
    # dependencies resolve through Mox. Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first; from the
    # checkout on, every write of this process commits.
    tenant = fixture(:committed_tenant, %{})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])

    ctx = build_story(tenant)
    on_exit(fn -> purge_tenant(tenant.id) end)

    ctx
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
      record_thread_allow(ctx, ctx.checkpoint, @head)
      story = AdminRepo.get!(Story, ctx.story_id)
      {:ok, route} = DispatchPayload.dispatch_route(ctx.tenant_id, story)
      {:ok, branch} = DispatchPayload.thread_branch(route, story, nil)
      stub_forge(branch)
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

      stub_ancestors(%{{@merge, @base_head} => true})
      assert {:already_merged, @merge} = MergeExecutor.run(ctx.tenant_id, ctx.story_id)
    end
  end

  # The claim's implement dispatch, PLACED in thread mode on `master` — the gate reads the
  # mode, the base branch and the branch from this row, never from the intake source — and the
  # claim's first checkpoint. Written to the ledger row directly: placement is
  # `DispatchLedger.record_sent/4`'s, tested there.
  defp thread_setup(ctx) do
    {_raw_key, runner} = fixture(:runner, %{tenant_id: ctx.tenant_id})

    {:ok, dispatch_row} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.insert!(%Loopctl.Runners.DispatchRecord{
          tenant_id: ctx.tenant_id,
          runner_id: runner.id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: ctx.story_id,
          claim_epoch: 0,
          kind: "implement",
          mode: "thread",
          base_branch: "master",
          # Released, so the row holds no slot and `runner_dispatches_unreleased_bounded`
          # has nothing to bound.
          status: "accepted",
          wall_clock_seconds: 3_600,
          released_at: DateTime.utc_now()
        })
      end)

    checkpoint =
      fixture(:thread_checkpoint, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        seq: 1,
        commit_sha: @head,
        tree_sha: @tree
      })

    # US-45.5: every recorded thread allow enqueues the merge executor, and Oban runs it
    # INLINE here. These tests judge the gate, so the executor finds the App unreachable —
    # a transient fault it answers by retrying later, which changes nothing now. The
    # executor's own behaviour is `Loopctl.Delivery.MergePreconditionIntegrationTest`'s
    # `merge executor (US-45.5)` block.
    Mox.stub(MockMergeForge, :session, fn _repo ->
      {:error, {:github_unreachable, :econnrefused}}
    end)

    %{checkpoint: checkpoint, dispatch_row: dispatch_row}
  end

  defp record_thread_allow(ctx, checkpoint, sha) do
    {:ok, _row} =
      Stages.record_effect(ctx.tenant_id, ctx.story_id, :merge_gate_allowed_sha, sha,
        claim_epoch: 0,
        event_data: %{
          "checkpoint_id" => checkpoint.id,
          "checkpoint_sha" => sha,
          "base_sha" => @base_head
        }
      )
  end

  defp stub_forge(branch) do
    Mox.stub(MockMergeForge, :session, fn @repo -> {:ok, @session} end)
    stub_base_head(@base_head, branch)

    Mox.stub(MockMergeForge, :commit, fn
      @session, @head -> {:ok, %{sha: @head, tree_sha: @tree, parents: [@base_head]}}
      @session, sha -> {:ok, %{sha: sha, tree_sha: @base_tree, parents: []}}
    end)

    stub_ancestors(%{{@base_head, @head} => true})
    Mox.stub(MockMergeForge, :create_commit, fn @session, _commit -> {:ok, @merge} end)
    Mox.stub(MockMergeForge, :update_ref, fn @session, "master", _sha -> :ok end)
    Mox.stub(MockMergeForge, :create_ref, fn @session, _temp, @head -> :ok end)
    Mox.stub(MockMergeForge, :delete_ref, fn @session, _temp -> :ok end)
    Mox.stub(MockMergeForge, :merge, fn _s, _b, _h, _m -> flunk("no base merge expected") end)
  end

  defp stub_base_head(base_head, branch) do
    Mox.stub(MockMergeForge, :branch_head, fn
      @session, "master" -> {:ok, base_head}
      @session, thread when thread == branch or is_nil(branch) -> {:ok, @head}
    end)
  end

  # `ancestor?/3` answers from `known`, false for any pair it does not name.
  defp stub_ancestors(known) do
    Mox.stub(MockMergeForge, :ancestor?, fn @session, ancestor, descendant ->
      {:ok, Map.get(known, {ancestor, descendant}, false)}
    end)
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

  defp build_story(tenant) do
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    verifier_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    fixture(:intake_source, %{
      tenant_id: tenant.id,
      project_id: project.id,
      repo_full_name: @repo,
      required_checks: ["test"]
    })

    {:ok, %{dispatch: implementer}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    {:ok, %{dispatch: verifier}} =
      Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: verifier_agent.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        verified_status: :verified,
        assigned_agent_id: agent.id,
        implementer_dispatch_id: implementer.id,
        verifier_dispatch_id: verifier.id
      })
      |> AdminRepo.update!()

    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :ci,
      claim_epoch: 0,
      pr_number: 4242,
      head_sha: @head
    })

    fixture(:triage_verdict, %{tenant_id: tenant.id, story_id: story.id})

    %{tenant_id: tenant.id, project_id: project.id, story_id: story.id}
  end

  # Three things block the sweep of a committed tenant, and all three are this module's own
  # committed test data: `dispatches` and `api_keys` have tenant FKs that do not cascade,
  # and `audit_chain` has one with a delete-BLOCKING trigger (entering `escalated` is a
  # chained transition, so every refusal appends to it).
  defp purge_tenant(tenant_id) do
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    purge_dependents("tenant_id = $1", [Ecto.UUID.dump!(tenant_id)])
  end

  # The same purge over every committed-runner tenant, then the tenants themselves. Run at
  # both module boundaries: an earlier run that died mid-test leaves rows behind, and the
  # sweep alone cannot delete a tenant they still reference.
  defp full_sweep do
    Sandbox.unboxed_run(Loopctl.Repo, fn ->
      purge_dependents(
        "tenant_id IN (SELECT id FROM tenants WHERE slug LIKE 'committed-runner-%')",
        []
      )
    end)

    sweep_committed_runner_tenants()
  end

  # ONE transaction around the trigger toggle and the deletes: DDL is transactional in
  # Postgres, so a failing DELETE rolls the DISABLE back with it. Run as separate
  # autocommitted statements, a failure in the middle would leave the audit chain's
  # delete-blocking trigger OFF for the rest of the run, in a database every branch on this
  # box shares.
  defp purge_dependents(predicate, params) do
    {:ok, :ok} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!(
          "ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        AdminRepo.query!("DELETE FROM audit_chain WHERE #{predicate}", params)

        # `stories` references both dispatch columns, so the refs go before the rows.
        AdminRepo.query!(
          "UPDATE stories SET implementer_dispatch_id = NULL, verifier_dispatch_id = NULL " <>
            "WHERE #{predicate}",
          params
        )

        AdminRepo.query!("DELETE FROM dispatches WHERE #{predicate}", params)
        AdminRepo.query!("DELETE FROM api_keys WHERE #{predicate}", params)

        AdminRepo.query!(
          "ALTER TABLE audit_chain ENABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        :ok
      end)

    :ok
  end
end
