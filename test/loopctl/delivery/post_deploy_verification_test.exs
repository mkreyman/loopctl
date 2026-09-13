defmodule Loopctl.Delivery.PostDeployVerificationTest do
  @moduledoc """
  `Loopctl.Delivery.PostDeployVerification.evaluate/2` and `enforce/3` end to end, plus the
  `Loopctl.Workers.PostDeployVerificationWorker` sweep that drives them (issue #803 §9).

  ## Why this module is `async: false` with committed rows

  The same reason `Loopctl.Delivery.MergePreconditionIntegrationTest` is: the verification
  reads the story and the intake source on `AdminRepo` and the stage row on `Loopctl.Repo`,
  and under `Ecto.Adapters.SQL.Sandbox` each repo is a SEPARATE owner with its own
  transaction, so a row one inserted is invisible to the other and its FKs fail. The rows
  here are COMMITTED under a `fixture(:committed_tenant)` and swept at module boundaries.

  The WORKER's tests live here rather than in a module of their own because its candidate
  read is on `AdminRepo` over rows this same setup commits: a separate module would be a
  second copy of a hundred lines of committed-tenant machinery for three tests.

  Everything decidable without any of this is in
  `Loopctl.Delivery.PostDeployVerificationJudgeTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.PostDeployVerification
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.Resolution
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo
  alias Loopctl.Workers.PostDeployVerificationWorker

  @repo "acme/widgets"
  @merge String.duplicate("a", 40)
  @deployed String.duplicate("b", 40)

  setup_all do
    full_sweep()
    on_exit(&full_sweep/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs, and the forge
    # resolves through Mox. Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed AdminRepo checkout, so it goes first.
    tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    ctx = build_story(tenant)
    on_exit(fn -> purge_tenant(tenant.id) end)

    ctx
  end

  describe "evaluate/2" do
    test "resolves the repository and the environment and reads the DEPLOYMENT", ctx do
      # Design §9: never the workflow run's head. The environment is fleet configuration,
      # never a caller's, and the repository comes from the story's intake source.
      Mox.expect(MockPullRequestSource, :latest_deployment, fn @repo, "production" ->
        {:ok, %{id: 91, sha: @merge, state: :success}}
      end)

      assert {:ok, %Result{decision: :verified} = result} = evaluate(ctx)
      assert result.repo == @repo
      assert result.merge_sha == @merge
      assert result.deployed_sha == @merge
      assert result.deployment_id == 91
    end

    test "the containment call is SKIPPED when the deployed commit is the merge itself", ctx do
      stub_deployment(sha: @merge)

      Mox.stub(MockPullRequestSource, :contains?, fn _repo, _sha, _ref ->
        flunk("a commit trivially contains itself; the round trip can only add a failure")
      end)

      assert {:ok, %Result{decision: :verified}} = evaluate(ctx)
    end

    test "a merge BEHIND the deployed commit is asked about, and shipped", ctx do
      stub_deployment()

      Mox.expect(MockPullRequestSource, :contains?, fn @repo, @merge, @deployed -> {:ok, true} end)

      assert {:ok, %Result{decision: :verified}} = evaluate(ctx)
    end

    test "resolves the repository from the intake source, never from the caller", ctx do
      %{num_rows: 1} =
        AdminRepo.query!("DELETE FROM intake_sources WHERE project_id = $1", [
          Ecto.UUID.dump!(ctx.project_id)
        ])

      Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env ->
        flunk("the forge must not be asked about a repository nothing could resolve")
      end)

      assert {:ok, %Result{decision: :failed, reasons: reasons}} = evaluate(ctx)
      assert Enum.any?(reasons, &match?({:repository_unresolved, {:no_intake_source, _}}, &1))
    end

    test "a story that is not in the tenant is :not_found", ctx do
      assert {:error, :not_found} =
               PostDeployVerification.evaluate(ctx.tenant_id, Ecto.UUID.generate())
    end

    test "a story that is not at the deployed stage is UNTOUCHED", ctx do
      set_stage(ctx, :merged)

      assert {:error, :wrong_stage} = evaluate(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :merged
    end

    test "a story with no stage row at all is :no_stage", ctx do
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in StoryStage, where: s.story_id == ^ctx.story_id) |> Repo.delete_all()
        end)

      assert {:error, :no_stage} = evaluate(ctx)
    end
  end

  describe "enforce/3" do
    test "a matching sha VERIFIES the story", ctx do
      stub_deployment(sha: @merge)

      assert {:ok, %Result{decision: :verified, reasons: []} = result} = enforce(ctx)
      assert result.resolution == Resolution.for_verdict(:shipped)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :verified
      assert row.attempts == %{}
    end

    test "a MISMATCH escalates on verification_failed, naming both shas", ctx do
      stub_deployment()
      Mox.stub(MockPullRequestSource, :contains?, fn _r, _s, _ref -> {:ok, false} end)

      assert {:ok, %Result{decision: :failed, reasons: reasons}} = enforce(ctx)
      assert {:merge_not_deployed, @merge, @deployed} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.attempts["verification_failed"] == 1
      assert row.escalation_reason =~ "merge_not_deployed"
      # Both shas, so the operator does not have to go and look them up.
      assert row.escalation_reason =~ @merge
      assert row.escalation_reason =~ @deployed
    end

    test "a FAILED deploy escalates rather than being read as shipped", ctx do
      stub_deployment(state: :failure)

      assert {:ok, %Result{decision: :failed, reasons: reasons}} = enforce(ctx)
      assert {:deploy_not_successful, :failure, @deployed, @merge} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "deploy_not_successful"
    end

    test "a ROLLED-BACK deploy escalates", ctx do
      # `inactive` on the NEWEST deployment of an environment is a deliberate
      # deactivation: nothing newer superseded it, because this is the newest one.
      stub_deployment(state: :inactive)

      assert {:ok, %Result{decision: :failed, reasons: reasons}} = enforce(ctx)
      assert {:deploy_not_successful, :inactive, @deployed, @merge} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "an environment with NO deployment escalates", ctx do
      Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env -> {:ok, nil} end)

      assert {:ok, %Result{decision: :failed, reasons: [{:no_deployment, "production"}]}} =
               enforce(ctx)

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end

    test "a TRANSIENT forge fault leaves the story at deployed, and is COUNTED", ctx do
      stub_unreachable()

      assert {:ok, %Result{decision: :unresolved, reasons: reasons}} = enforce(ctx)
      assert {:deployment_unavailable, {:github_unreachable, :timeout}} in reasons

      # One blip must not park a story on a human: `escalated` is human-only.
      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :deployed
      assert row.post_deploy_unresolved == %{"merge_sha" => @merge, "count" => 1}
    end

    test "a DEPLOY STILL RUNNING leaves the story at deployed, and is counted", ctx do
      stub_deployment(state: :pending)

      assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :deployed
      assert row.post_deploy_unresolved["count"] == 1
    end

    test "a fault that never clears ESCALATES once it passes the bound", ctx do
      # The backstop under "no condition may wait for ever with nobody told".
      stub_unreachable()
      limit = PostDeployVerification.max_consecutive_unresolved()

      for _attempt <- 1..limit do
        assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)
      end

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :deployed

      assert {:ok, %Result{decision: :failed, reasons: reasons}} = enforce(ctx)
      assert {:unresolved_limit_exceeded, limit + 1} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      # The escalation names the fault, not just the count.
      assert row.escalation_reason =~ "unresolved_limit_exceeded"
      assert row.escalation_reason =~ "github_unreachable"
    end

    test "a verdict CLEARS the count a run of unresolved sweeps left behind", ctx do
      stub_unreachable()
      assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)
      assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).post_deploy_unresolved["count"] == 2

      stub_deployment(sha: @merge)
      assert {:ok, %Result{decision: :verified}} = enforce(ctx)

      assert is_nil(Stages.get(ctx.tenant_id, ctx.story_id).post_deploy_unresolved)
    end

    test "the count is kept per the MERGE, and it and every write leave an event", ctx do
      stub_unreachable()
      assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)

      assert [%StageEvent{event: "post_deploy_unresolved", data: data}] =
               ctx.tenant_id
               |> Stages.list_events(ctx.story_id)
               |> Enum.filter(&(&1.event == "post_deploy_unresolved"))

      assert data == %{"merge_sha" => @merge, "count" => 1}
    end

    test "a repeated sweep does not verify twice", ctx do
      stub_deployment(sha: @merge)

      assert {:ok, %Result{decision: :verified}} = enforce(ctx)
      # The row is at `verified` now, so the second ask cannot even reach a verdict.
      assert {:error, :wrong_stage} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :verified
    end

    test "a repeated sweep does not escalate twice", ctx do
      stub_deployment(state: :failure)

      assert {:ok, %Result{decision: :failed}} = enforce(ctx)
      assert {:error, :wrong_stage} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).attempts["verification_failed"] == 1
    end

    test "a stale claim epoch cannot verify, and the verdict still stands", ctx do
      stub_deployment(sha: @merge)

      assert {:ok, %Result{decision: :verified, reasons: reasons}} =
               PostDeployVerification.enforce(
                 ctx.tenant_id,
                 ctx.story_id,
                 Keyword.put(opts(), :claim_epoch, 99)
               )

      assert {:transition_failed, :verified, :forward, :stale_claim_epoch} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :deployed
    end

    test "a stale claim epoch cannot escalate either, and the failure is reported", ctx do
      stub_deployment(state: :failure)

      assert {:ok, %Result{decision: :failed, reasons: reasons}} =
               PostDeployVerification.enforce(
                 ctx.tenant_id,
                 ctx.story_id,
                 Keyword.put(opts(), :claim_epoch, 99)
               )

      assert {:transition_failed, :escalated, :verification_failed, :stale_claim_epoch} in reasons
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :deployed
    end

    test "a transition that did NOT land does not clear the unresolved count", ctx do
      # The race this guards, staged: the row moves after the stage was read and before the
      # compare-and-set, so the advance is refused `:stale_stage` while the epoch-fenced
      # CLEAR would still succeed. Clearing there resets the backstop on the strength of a
      # write that failed. The forge stub is the hook — `evaluate/2` reads the stage row
      # first and gathers second, so a move made here lands in exactly that window.
      stub_unreachable()
      assert {:ok, %Result{decision: :unresolved}} = enforce(ctx)
      assert Stages.get(ctx.tenant_id, ctx.story_id).post_deploy_unresolved["count"] == 1

      Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env ->
        {:ok, {1, _}} =
          Repo.with_tenant(ctx.tenant_id, fn ->
            from(s in StoryStage, where: s.story_id == ^ctx.story_id)
            |> Repo.update_all(set: [stage: :escalated, escalation_reason: "raced"])
          end)

        {:ok, %{id: 91, sha: @merge, state: :success}}
      end)

      assert {:ok, %Result{decision: :verified, reasons: reasons}} = enforce(ctx)
      assert {:transition_failed, :verified, :forward, :stale_stage} in reasons

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.post_deploy_unresolved["count"] == 1
    end

    test "a long reason list is TRUNCATED so the escalation is still written", ctx do
      # An over-long reason would roll the transition back and leave the story at `deployed`
      # with nothing recorded, which is the one outcome a fail-closed gate cannot have.
      long = String.duplicate("x", 8_000)
      stub_deployment(state: :failure, sha: long)

      assert {:ok, %Result{decision: :failed}} = enforce(ctx)

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      # Bounded in CODEPOINTS with a margin under the 4000 the DB CHECK counts.
      assert row.escalation_reason |> String.to_charlist() |> length() == 3_900
      assert String.ends_with?(row.escalation_reason, "…")
    end
  end

  describe "the sweep" do
    test "verifies a story at deployed, and touches one at any other stage NOT AT ALL", ctx do
      other = build_story(%{id: ctx.tenant_id}, "acme/other")
      set_stage(other, :merged)
      stub_deployment(sha: @merge)

      assert :ok = perform_job(PostDeployVerificationWorker, %{})

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :verified
      assert Stages.get(other.tenant_id, other.story_id).stage == :merged
    end

    test "is idempotent: a second run writes nothing", ctx do
      stub_deployment(sha: @merge)

      assert :ok = perform_job(PostDeployVerificationWorker, %{})
      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :verified

      assert :ok = perform_job(PostDeployVerificationWorker, %{})
      assert Stages.get(ctx.tenant_id, ctx.story_id).lock_version == row.lock_version
    end

    test "a rate-limited forge HALTS the run rather than spending the rest of the window",
         ctx do
      # The remaining candidates would ask a forge that has already said it is out of quota.
      _second = build_story(%{id: ctx.tenant_id}, "acme/other")

      calls = :counters.new(1, [])

      Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env ->
        :counters.add(calls, 1, 1)
        {:error, {:github_rate_limited, 403, 60}}
      end)

      assert :ok = perform_job(PostDeployVerificationWorker, %{})
      assert :counters.get(calls, 1) == 1
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp evaluate(ctx), do: PostDeployVerification.evaluate(ctx.tenant_id, ctx.story_id)
  defp enforce(ctx), do: PostDeployVerification.enforce(ctx.tenant_id, ctx.story_id, opts())

  defp opts do
    [
      claim_epoch: 0,
      actor_label: "test",
      # Entering `escalated` is a CHAINED transition, and `Stages.advance/4` refuses one
      # that does not declare the actor's lineage. A cron sweep legitimately has none.
      actor_lineage: []
    ]
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})

  defp stub_deployment(opts \\ []) do
    deployment = %{
      id: 91,
      sha: Keyword.get(opts, :sha, @deployed),
      state: Keyword.get(opts, :state, :success)
    }

    Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env -> {:ok, deployment} end)
  end

  defp stub_unreachable do
    Mox.stub(MockPullRequestSource, :latest_deployment, fn _repo, _env ->
      {:error, {:github_unreachable, :timeout}}
    end)
  end

  defp set_stage(ctx, stage) do
    {:ok, {1, _}} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        from(s in StoryStage, where: s.story_id == ^ctx.story_id)
        |> Repo.update_all(set: [stage: stage])
      end)

    :ok
  end

  # `repo` is a parameter because `intake_sources_active_repo_uidx` is GLOBAL: only one
  # active source may bind a repository, so a second story in the same tenant needs its own.
  defp build_story(tenant, repo \\ @repo) do
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    fixture(:intake_source, %{
      tenant_id: tenant.id,
      project_id: project.id,
      repo_full_name: repo
    })

    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})

    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :deployed,
      claim_epoch: 0,
      pr_number: 4242,
      merge_sha: @merge,
      release_id: "v586"
    })

    %{tenant_id: tenant.id, project_id: project.id, story_id: story.id}
  end

  # `audit_chain` has a tenant FK with a delete-BLOCKING trigger, and entering `escalated`
  # is a chained transition, so every escalation here appends to it.
  #
  # The tenant itself goes too, which the merge precondition's equivalent does not need to
  # do. The WORKER's candidate read is fleet-wide and bounded at `batch_size/0`, so a test
  # whose committed story survives its own test leaves a story at `deployed` that later
  # sweep tests then compete with for the batch — and past the bound the sweep tests stop
  # seeing their own story at all.
  defp purge_tenant(tenant_id) do
    checkout_admin()
    dumped = Ecto.UUID.dump!(tenant_id)
    purge_dependents("tenant_id = $1", [dumped])
    AdminRepo.query!("DELETE FROM tenants WHERE id = $1", [dumped])
    :ok
  end

  defp full_sweep do
    Sandbox.unboxed_run(AdminRepo, fn ->
      purge_dependents(
        "tenant_id IN (SELECT id FROM tenants WHERE slug LIKE 'committed-runner-%')",
        []
      )
    end)

    sweep_committed_runner_tenants()
  end

  defp purge_dependents(predicate, params) do
    {:ok, :ok} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!(
          "ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        AdminRepo.query!("DELETE FROM audit_chain WHERE #{predicate}", params)

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

  defp checkout_admin do
    case Sandbox.checkout(AdminRepo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
