defmodule Loopctl.Workers.VerificationRunnerWorkerIntegrationTest do
  @moduledoc """
  US-26.4.6 end to end through `VerificationRunnerWorker.perform/1`: every path that reads the
  forge, which needs the story's BRANCH.

  The branch lives on the RLS `Loopctl.Repo` (the dispatch ledger and the stage row), while
  the run, its story and the intake source live on `AdminRepo`, and `verification_runs`
  references `stories`. AdminRepo shares Repo's sandbox connection in test, so every row is
  sandboxed and the module runs async. The forge mock is process-scoped: the worker runs in
  the test process, so no test answers another's reads (`Loopctl.Test.VerificationRunnerForge`
  holds the stubs and their wrong-read trap).

  The paths whose subject is a lock another connection holds (a write loopctl cannot make, a
  stage row or ledger it cannot read) are in `Loopctl.Workers.VerificationRunnerWorkerLockTest`.
  Every path that needs no branch is in `VerificationRunnerWorkerTest`.
  """

  use Loopctl.DataCase, async: true

  import Loopctl.Test.VerificationRunnerForge

  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Test.VerificationRunnerForge
  alias Loopctl.Verification.Credential

  @repo VerificationRunnerForge.repo()
  @branch VerificationRunnerForge.branch()
  @sha VerificationRunnerForge.sha()
  @short VerificationRunnerForge.short()
  @fork_point VerificationRunnerForge.fork_point()
  @base_tree VerificationRunnerForge.base_tree()

  setup :verify_on_exit!

  setup do
    setup_story!(fixture(:tenant, %{trust_tier: :agent_rooted}).id)
  end

  defp refute_wrong_reads, do: refute_received({:wrong_read, _, _, _})

  # -- TC-26.4.6.1 --------------------------------------------------------------------------

  describe "TC-26.4.6.1 only the story's branch in the intake source's repository is read" do
    test "pr mode: the branch the stage row records, in the intake source's repository", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      # On the story's own branch `test` FAILED; anything else would read green.
      stub_forge(ctx, %{
        evidence: build(:forge_evidence, %{status: "completed", conclusion: "failure"})
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "fail"

      assert reloaded.ac_results["evidence_url"] ==
               "https://github.com/acme/widgets/actions/runs/5/job/50"

      assert_received {:evidence, @sha}
      refute_wrong_reads()
    end

    test "thread mode: DispatchPayload.thread_branch/3 and the base the claim was placed on",
         ctx do
      # The stage row names a STALE branch; the ledger's route names the claim's own.
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: "loop/stale"
      })

      place_thread!(ctx, "loop/thread-branch", "release")

      stub_forge(ctx, %{
        branch: "loop/thread-branch",
        base: "release",
        evidence: build(:forge_evidence, %{status: "completed", conclusion: "failure"})
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert reload(ctx, run).status == "fail"
      refute_wrong_reads()
    end
  end

  # -- TC-26.4.6.6 / AC-26.4.6.8 -------------------------------------------------------------

  describe "TC-26.4.6.6 the credential is asked for the (tenant, repository) pair" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    test "it is asked for the intake source's repository, never projects.repo_url", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      tenant_id = ctx.tenant_id
      assert_received {:credential_asked, ^tenant_id, @repo}
      refute_received {:credential_asked, _, _}
      assert reload(ctx, run).status == "pass"
    end

    test "a pair with no credential records credential_unavailable, no request made", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})

      # Allowlisted for ANOTHER repository only: this story's is not licensed.
      stub(MockVerificationCredential, :for_read, fn _tenant_id, repo ->
        if repo == "acme/other",
          do: {:ok, %Credential{kind: :operator_token, repo: ForgeRepo.operator(repo)}},
          else: {:error, :credential_unavailable}
      end)

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "error"

      assert reloaded.ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "credential_unavailable"
             }

      refute_received {:compare, _}
      refute_received {:evidence, _}
    end

    # #931 finding g: the rescue arm records a code, never the exception.
    test "a crash records internal_error with no exception text, and cancels", ctx do
      stub(MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        raise "leaky detail acme/private-repo"
      end)

      run = fixture(:verification_run, ctx)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
      assert result == {:cancel, :internal_error}
      assert log =~ "leaky detail"

      reloaded = reload(ctx, run)
      assert reloaded.status == "error"

      assert reloaded.ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "internal_error"
             }
    end
  end

  # -- TC-26.4.6.2 --------------------------------------------------------------------------

  describe "TC-26.4.6.2 required checks decide, one run per outcome" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    test "test pending is a wait: the run stays running and the job snoozes", ctx do
      stub_forge(ctx, %{
        evidence:
          build(:forge_evidence, %{
            runs: [build(:ci_run, %{status: "in_progress", conclusion: nil}), build(:lint_run)],
            jobs: [build(:ci_job, %{status: "in_progress", conclusion: nil}), build(:lint_job)]
          })
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, 60} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end

    test "test failed is a fail, whatever an unrelated workflow said", ctx do
      stub_forge(ctx, %{
        evidence:
          build(:forge_evidence, %{
            runs: [
              build(:ci_run, %{status: "completed", conclusion: "failure"}),
              build(:lint_run)
            ],
            jobs: [
              build(:ci_job, %{status: "completed", conclusion: "failure"}),
              build(:lint_job)
            ]
          })
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "fail", ac_results: %{"failed_check" => "test", "conclusion" => "failure"}} =
               reload(ctx, run)
    end

    test "test succeeded is a pass naming the judged run", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence)})

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "pass", ac_results: ac} = reload(ctx, run)

      assert ac == %{
               "source" => "ci",
               "evidence_url" => "https://github.com/acme/widgets/actions/runs/5"
             }
    end

    test "only an unrelated workflow succeeded: never a pass", ctx do
      stub_forge(ctx, %{
        evidence: build(:forge_evidence, %{runs: [build(:lint_run)], jobs: [build(:lint_job)]})
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end
  end

  # -- TC-26.4.6.3 --------------------------------------------------------------------------

  describe "TC-26.4.6.3 a workflow edit is refused" do
    test "no verdict, ci_definition_changed, and no evidence read", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      stub_forge(ctx, %{diff: [".github/workflows/ci.yml"], evidence: build(:forge_evidence)})

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: ac} = reload(ctx, run)
      assert ac == %{"source" => "ci", "ci_unavailable_reason" => "ci_definition_changed"}
      refute_received {:evidence, _}
    end

    test "an unreadable diff is ci_definition_unknown", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      stub_forge(ctx, %{
        compare:
          {:ok,
           %{
             merge_base_sha: @fork_point,
             base_tree_sha: @base_tree,
             diffstat: %{files: 300, changed_lines: 900},
             diff: {:error, {:file_list_truncated, 300}}
           }},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "ci_definition_unknown"
    end
  end

  # -- AC-26.4.6.3: the change check, once per run ---------------------------------------

  describe "AC-26.4.6.3 the change check is the merge gate's, once per run" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    test "an old green commit of the base (its own merge base) is empty_change", ctx do
      stub_forge(ctx, %{
        compare: {:ok, build(:forge_comparison, %{merge_base_sha: @sha})},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert reload(ctx, run).ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "empty_change"
             }

      refute_received {:evidence, _}
    end

    # The round-2 check (`merge_base == sha`) let this through: an empty commit's merge base
    # is its parent. Only the diff tells.
    test "an empty commit on top of an old base commit is empty_change", ctx do
      stub_forge(ctx, %{
        compare: {:ok, build(:forge_comparison, %{merge_base_sha: @fork_point})},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "empty_change"
      refute_received {:evidence, _}
    end

    # Checked once, then merged during the CI wait: the next comparison would be empty, and it
    # is never asked.
    test "a commit checked once is still judged after a merge empties its diff", ctx do
      stub_forge(ctx, %{
        evidence:
          sequence([
            build(:forge_evidence, %{status: "in_progress", conclusion: nil}),
            build(:forge_evidence)
          ])
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert_received {:compare, @sha}
      assert %{change_checked_at: %DateTime{}} = reload(ctx, run)

      # Merged: the comparison now answers an empty diff.
      stub(MockPullRequestSource, :compare, fn %ForgeRepo{full_name: @repo}, "master", sha ->
        send(ctx.test_pid, {:compare, sha})
        {:ok, build(:forge_comparison, %{merge_base_sha: @sha})}
      end)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
      refute_received {:compare, _}
    end

    # Round 4, finding 5: the merge gate's rule, both halves. A head whose tree is the base's
    # is empty however many files its three-dot diff lists.
    test "a head whose tree is the base's is empty_change, whatever the diff lists", ctx do
      stub_forge(ctx, %{tree: @base_tree, evidence: build(:forge_evidence)})

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "empty_change"
      assert_received {:commit, @sha}
      refute_received {:evidence, _}
    end
  end

  # -- TC-26.4.6.4 --------------------------------------------------------------------------

  describe "TC-26.4.6.4 transient waits, permanent ends, age ends" do
    setup ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      :ok
    end

    # #915 round 3, finding 1: one blip must not end a run.
    test "a 502 once then success: a snooze, then a pass", ctx do
      stub_forge(ctx, %{
        evidence: sequence([{:error, {:github_api_error, 502}}, build(:forge_evidence)])
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, _} = perform(ctx, run)
      waiting = reload(ctx, run)
      assert waiting.status == "running"
      assert waiting.ci_forge_faults == 1

      assert :ok = perform(ctx, waiting)
      assert reload(ctx, run).status == "pass"
    end

    # Review round 1, finding 3: the snooze backs off with the STREAK, so the bound spans
    # tens of minutes of an unreachable forge rather than a few.
    test "a 502 past the merge gate's consecutive bound records forge_unavailable", ctx do
      stub_forge(ctx, %{
        compare: {:error, {:github_api_error, 502}},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      bound = MergePrecondition.max_consecutive_unevaluated()
      backoff = [60, 120, 240, 480, 900, 900, 900]

      for n <- 1..bound do
        expected = Enum.at(backoff, n - 1)
        assert {:snooze, ^expected} = perform(ctx, run), "fault #{n}"
        assert reload(ctx, run).ci_forge_faults == n
      end

      assert :ok = perform(ctx, run)
      reloaded = reload(ctx, run)
      assert reloaded.status == "error"

      # A final no-verdict records its code and ends the run: nothing else is recorded.
      assert reloaded.ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "forge_unavailable"
             }
    end

    # Round 2, finding 1: the evidence read faults every poll. The comparison that answered on
    # the first poll resets nothing, so the streak still reaches the bound; and it is asked
    # only once (round 3: the change check runs once per run).
    test "an evidence read that faults every poll reaches forge_unavailable at the bound", ctx do
      stub_forge(ctx, %{evidence: {:error, {:github_api_error, 503}}})
      run = fixture(:verification_run, ctx)
      bound = MergePrecondition.max_consecutive_unevaluated()

      for n <- 1..bound do
        assert {:snooze, _} = perform(ctx, run), "fault #{n}"
        if n == 1, do: assert_received({:compare, @sha}), else: refute_received({:compare, _})
        assert reload(ctx, run).ci_forge_faults == n
      end

      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: %{"ci_unavailable_reason" => "forge_unavailable"}} =
               reload(ctx, run)
    end

    test "a forge-supplied retry-after is honoured up to an hour", ctx do
      stub_forge(ctx, %{
        compare: {:error, {:github_rate_limited, 429, 7_200}},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, 3_600} = perform(ctx, run)
    end

    test "an answered wait resets the fault streak", ctx do
      stub_forge(ctx, %{
        evidence:
          sequence([
            {:error, {:github_unreachable, :timeout}},
            build(:forge_evidence, %{status: "queued", conclusion: nil})
          ])
      })

      run = fixture(:verification_run, ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 1
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 0
    end

    test "a 404 records its code at once, and ends the run", ctx do
      stub_forge(ctx, %{
        compare: {:error, {:github_api_error, 404}},
        evidence: build(:forge_evidence)
      })

      run = fixture(:verification_run, ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: ac} = reload(ctx, run)
      assert ac == %{"source" => "ci", "ci_unavailable_reason" => "forge_not_found"}
    end

    test "a missing required check past the age window records ci_wait_exhausted", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence, %{runs: [], jobs: []})})

      run = fixture(:verification_run, Map.put(ctx, :age_seconds, 25 * 60 * 60))
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "ci_wait_exhausted"
    end

    test "inside the window a missing check waits", ctx do
      stub_forge(ctx, %{evidence: build(:forge_evidence, %{runs: [], jobs: []})})

      run = fixture(:verification_run, Map.put(ctx, :age_seconds, 23 * 60 * 60))
      assert {:snooze, _} = perform(ctx, run)
    end

    test "a transient fault past the age window records forge_unavailable", ctx do
      stub_forge(ctx, %{evidence: {:error, {:github_api_error, 503}}})

      run = fixture(:verification_run, Map.put(ctx, :age_seconds, 25 * 60 * 60))
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "forge_unavailable"
    end

    # #931 finding e: a secondary rate limit is a 403 with a retry-after — waited, at least
    # as long as the forge asked.
    test "a rate limit waits at least the forge's own delay", ctx do
      stub_forge(ctx, %{evidence: {:error, {:github_rate_limited, 403, 600}}})

      run = fixture(:verification_run, ctx)
      assert {:snooze, 600} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end

    # #931 finding i: the snooze backs off with the run's age instead of a fixed 60s.
    test "the snooze backs off with age, between one and fifteen minutes", ctx do
      stub_forge(ctx, %{
        evidence: build(:forge_evidence, %{status: "queued", conclusion: nil})
      })

      for {age, snooze} <- [{0, 60}, {2 * 60 * 60, 720}, {10 * 60 * 60, 900}] do
        run = fixture(:verification_run, Map.put(ctx, :age_seconds, age))
        # The age is measured a moment after it was set: allow that second.
        assert {:snooze, got} = perform(ctx, run)
        assert got in (snooze - 1)..snooze, "age #{age}: snoozed #{got}, expected #{snooze}"
      end
    end
  end

  # -- TC-26.4.6.5 --------------------------------------------------------------------------

  describe "TC-26.4.6.5 an abbreviated SHA is resolved once per run" do
    test "one commit read across polls; the run carries the full SHA and the failing job", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      stub_forge(ctx, %{
        evidence:
          sequence([
            build(:forge_evidence, %{status: "in_progress", conclusion: nil}),
            build(:forge_evidence, %{status: "in_progress", conclusion: nil}),
            build(:forge_evidence, %{status: "completed", conclusion: "failure"})
          ])
      })

      expect(MockPullRequestSource, :resolve_commit, 1, fn %ForgeRepo{full_name: @repo}, @short ->
        {:ok, @sha}
      end)

      run = fixture(:verification_run, Map.put(ctx, :commit_sha, @short))
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).resolved_commit_sha == @sha
      assert {:snooze, _} = perform(ctx, run)
      assert :ok = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "fail"
      assert reloaded.commit_sha == @short
      assert reloaded.resolved_commit_sha == @sha

      assert reloaded.ac_results["evidence_url"] ==
               "https://github.com/acme/widgets/actions/runs/5/job/50"

      # Every read after the resolution used the FULL id.
      assert_received {:evidence, @sha}
      refute_received {:evidence, @short}
    end

    # Round 2, finding 1: resolving happens once per run and is not a CI answer, so it leaves
    # the streak alone. The comparison after it faulted: the fifth fault, not a new first.
    test "resolving an abbreviated SHA leaves the fault streak alone", ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      stub_forge(ctx, %{
        compare: {:error, {:github_api_error, 502}},
        evidence: build(:forge_evidence)
      })

      expect(MockPullRequestSource, :resolve_commit, 1, fn %ForgeRepo{full_name: @repo}, @short ->
        {:ok, @sha}
      end)

      run = fixture(:verification_run, Map.merge(ctx, %{commit_sha: @short, ci_forge_faults: 4}))
      assert {:snooze, 900} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.resolved_commit_sha == @sha
      assert reloaded.ci_forge_faults == 5
    end

    test "an unresolvable prefix and an unreadable repository are permanent",
         ctx do
      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: ctx.story_id,
        stage: :implementing,
        branch: @branch
      })

      stub_forge(ctx, %{evidence: build(:forge_evidence)})

      for {status, code} <- [{422, "unresolved_sha"}, {404, "repository_unreadable"}] do
        expect(MockPullRequestSource, :resolve_commit, fn %ForgeRepo{full_name: @repo}, @short ->
          {:error, {:github_api_error, status}}
        end)

        run = fixture(:verification_run, Map.put(ctx, :commit_sha, @short))
        assert :ok = perform(ctx, run)
        assert reload(ctx, run).ac_results == %{"source" => "ci", "ci_unavailable_reason" => code}
      end

      refute_received {:evidence, _}
    end
  end

  # -- plumbing ------------------------------------------------------------------------------

  defp place_thread!(ctx, branch, base_branch) do
    runner = fixture(:stage_runner, %{tenant_id: ctx.tenant_id})

    {:ok, _row} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        Repo.insert!(%Loopctl.Runners.DispatchRecord{
          tenant_id: ctx.tenant_id,
          runner_id: runner.id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: ctx.story_id,
          claim_epoch: 0,
          kind: "implement",
          mode: "thread",
          branch: branch,
          base_branch: base_branch,
          status: "accepted",
          wall_clock_seconds: 3_600,
          released_at: DateTime.utc_now()
        })
      end)
  end
end
