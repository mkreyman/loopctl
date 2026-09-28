defmodule Loopctl.Workers.VerificationRunnerWorkerIntegrationTest do
  @moduledoc """
  US-26.4.6 end to end through `VerificationRunnerWorker.perform/1`: every path that reads the
  forge, which needs the story's BRANCH.

  ## Why this module is `async: false` with committed rows

  The branch lives on the RLS `Loopctl.Repo` (the dispatch ledger and the stage row), while
  the run, its story and the intake source live on `AdminRepo`, and `verification_runs`
  references `stories`. Under `Ecto.Adapters.SQL.Sandbox` those are two owners with two
  transactions that cannot see each other's rows, so — exactly as
  `Loopctl.Delivery.MergePreconditionIntegrationTest` does for the merge gate — the rows are
  COMMITTED under a `fixture(:committed_tenant)`. Every path that needs no branch is in the
  `async: true` `VerificationRunnerWorkerTest`. It is `async: false` because the rows are
  committed and the forge mock is GLOBAL (`Mox.set_mox_global/0`), so two tests at once would
  answer each other's reads.

  Cleanup deletes ONLY what this module created: each test's own tenant, by id, on exit
  (`purge/1`, then `sweep_committed_tenants/1`). Never the `committed-runner-%` slug sweep: every
  worktree on a box shares one test database, and that sweep deletes the committed rows of a
  suite running concurrently in another tree.

  The forge is `Loopctl.MockPullRequestSource` (global mode). Each stub answers ONLY for the
  intake source's repository and the story's own branch; anything else is recorded as
  `{:wrong_read, ...}` and answered with green evidence, so reading the wrong repository or
  branch shows up as a wrong VERDICT, not only as a missing message.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Repo
  alias Loopctl.Verification
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.VerificationRun
  alias Loopctl.Workers.VerificationRunnerWorker

  @repo "acme/widgets"
  @branch "loop/story-branch"
  @sha String.duplicate("a", 40)
  @short "aaaaaaa"
  @fork_point String.duplicate("b", 40)
  @head_tree String.duplicate("e", 40)
  @base_tree String.duplicate("f", 40)

  setup do
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    on_exit(fn ->
      purge(tenant.id)
      sweep_committed_tenants([tenant.id])
    end)

    # `repo_url` names ANOTHER repository: nothing may read it (#931 finding a).
    project =
      fixture(:project, %{tenant_id: tenant.id, repo_url: "https://github.com/evil/other"})

    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})

    fixture(:intake_source, %{
      tenant_id: tenant.id,
      project_id: project.id,
      repo_full_name: @repo,
      required_checks: ["test"]
    })

    test_pid = self()

    stub(MockVerificationCredential, :any_for_tenant?, fn _tenant_id -> true end)

    stub(MockVerificationCredential, :for_read, fn tenant_id, repo ->
      send(test_pid, {:credential_asked, tenant_id, repo})
      {:ok, %Credential{kind: :operator_token}}
    end)

    %{tenant_id: tenant.id, project_id: project.id, story_id: story.id, test_pid: test_pid}
  end

  # -- helpers ---------------------------------------------------------------------------

  defp stage_branch!(ctx, branch) do
    fixture(:story_stage, %{
      tenant_id: ctx.tenant_id,
      story_id: ctx.story_id,
      stage: :implementing,
      branch: branch
    })
  end

  defp run!(ctx, sha \\ @sha) do
    {:ok, run} = Verification.create_run(ctx.tenant_id, ctx.story_id, %{commit_sha: sha})
    run
  end

  defp perform(ctx, run) do
    VerificationRunnerWorker.perform(%Oban.Job{
      args: %{"run_id" => run.id, "tenant_id" => ctx.tenant_id}
    })
  end

  defp reload(ctx, run) do
    {:ok, reloaded} = Verification.get_run(ctx.tenant_id, run.id)
    reloaded
  end

  defp age!(run, seconds_ago, started? \\ true) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    set = [inserted_at: at] ++ if(started?, do: [started_at: at, status: "running"], else: [])
    {1, _} = AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id), set: set)
    run
  end

  defp green(run_id \\ 5),
    do:
      evidence([ci_run(run_id, "completed", "success")], [ci_job(run_id, "completed", "success")])

  defp evidence(runs, jobs), do: {:ok, %{runs: runs, jobs: jobs, statuses: []}}

  defp ci_run(id, status, conclusion, workflow \\ ".github/workflows/ci.yml"),
    do: %{id: id, workflow: workflow, status: status, conclusion: conclusion}

  # An unrelated workflow file (`lint.yml`) that succeeded, carrying its own job.
  defp lint_run(id), do: ci_run(id, "completed", "success", ".github/workflows/lint.yml")

  defp lint_job(run_id),
    do: %{ci_job(run_id, "completed", "success", "lint") | workflow: ".github/workflows/lint.yml"}

  defp ci_job(run_id, status, conclusion, name \\ "test"),
    do: %{
      id: run_id * 10,
      run_id: run_id,
      name: name,
      status: status,
      conclusion: conclusion,
      workflow: ".github/workflows/ci.yml"
    }

  # The story's own reads answer `answers`; any other repository, branch or base is recorded
  # and answered GREEN, so a read of the wrong target would pass a run that must not pass.
  defp stub_forge(ctx, answers) do
    base = Map.get(answers, :base, "master")
    branch = Map.get(answers, :branch, @branch)
    diff = Map.get(answers, :diff, ["lib/widgets/thing.ex"])

    stub(MockPullRequestSource, :commit, fn
      @repo, sha ->
        send(ctx.test_pid, {:commit, sha})
        {:ok, %{tree_sha: Map.get(answers, :tree, @head_tree), parents: [@fork_point]}}

      repo, _sha ->
        send(ctx.test_pid, {:wrong_read, :commit, repo, nil})
        {:ok, %{tree_sha: @head_tree, parents: []}}
    end)

    stub(MockPullRequestSource, :compare, fn
      @repo, ^base, sha ->
        send(ctx.test_pid, {:compare, sha})
        answers |> Map.get_lazy(:compare, fn -> {:ok, clean(diff)} end) |> answer()

      repo, other_base, _sha ->
        send(ctx.test_pid, {:wrong_read, :compare, repo, other_base})
        {:ok, clean(["lib/x.ex"])}
    end)

    stub(MockPullRequestSource, :check_evidence, fn
      @repo, sha, ^branch ->
        send(ctx.test_pid, {:evidence, sha})
        answers |> Map.fetch!(:evidence) |> answer()

      repo, _sha, other_branch ->
        send(ctx.test_pid, {:wrong_read, :check_evidence, repo, other_branch})
        green(99)
    end)
  end

  # An answer given as a value, or as a function called at the read.
  defp answer(fun) when is_function(fun, 0), do: fun.()
  defp answer(value), do: value

  defp clean(files, merge_base \\ @fork_point),
    do: %{
      merge_base_sha: merge_base,
      base_tree_sha: @base_tree,
      diffstat: %{files: length(files), changed_lines: 3 * length(files)},
      diff: {:ok, %{files: files, renames: []}}
    }

  defp refute_wrong_reads, do: refute_received({:wrong_read, _, _, _})

  # A sequence of answers, one per call, from a process-held queue.
  defp sequence(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn ->
      Agent.get_and_update(agent, fn
        [only] -> {only, [only]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  # -- TC-26.4.6.1 --------------------------------------------------------------------------

  describe "TC-26.4.6.1 only the story's branch in the intake source's repository is read" do
    test "pr mode: the branch the stage row records, in the intake source's repository", ctx do
      stage_branch!(ctx, @branch)
      # On the story's own branch `test` FAILED; anything else would read green.
      stub_forge(ctx, %{
        evidence:
          evidence([ci_run(5, "completed", "failure")], [ci_job(5, "completed", "failure")])
      })

      run = run!(ctx)
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
      stage_branch!(ctx, "loop/stale")
      place_thread!(ctx, "loop/thread-branch", "release")

      stub_forge(ctx, %{
        branch: "loop/thread-branch",
        base: "release",
        evidence:
          evidence([ci_run(5, "completed", "failure")], [ci_job(5, "completed", "failure")])
      })

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert reload(ctx, run).status == "fail"
      refute_wrong_reads()
    end
  end

  # -- TC-26.4.6.6 / AC-26.4.6.8 -------------------------------------------------------------

  describe "TC-26.4.6.6 the credential is asked for the (tenant, repository) pair" do
    setup ctx do
      stage_branch!(ctx, @branch)
      :ok
    end

    test "it is asked for the intake source's repository, never projects.repo_url", ctx do
      stub_forge(ctx, %{evidence: green()})

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      tenant_id = ctx.tenant_id
      assert_received {:credential_asked, ^tenant_id, @repo}
      refute_received {:credential_asked, _, _}
      assert reload(ctx, run).status == "pass"
    end

    test "a pair with no credential records credential_unavailable, no request made", ctx do
      stub_forge(ctx, %{evidence: green()})

      # Allowlisted for ANOTHER repository only: this story's is not licensed.
      stub(MockVerificationCredential, :for_read, fn _tenant_id, repo ->
        if repo == "acme/other",
          do: {:ok, %Credential{kind: :operator_token}},
          else: {:error, :credential_unavailable}
      end)

      run = run!(ctx)
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

      run = run!(ctx)

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
      stage_branch!(ctx, @branch)
      :ok
    end

    test "test pending is a wait: the run stays running and the job snoozes", ctx do
      stub_forge(ctx, %{
        evidence:
          evidence(
            [ci_run(5, "in_progress", nil), lint_run(6)],
            [ci_job(5, "in_progress", nil), lint_job(6)]
          )
      })

      run = run!(ctx)
      assert {:snooze, 60} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end

    test "test failed is a fail, whatever an unrelated workflow said", ctx do
      stub_forge(ctx, %{
        evidence:
          evidence(
            [ci_run(5, "completed", "failure"), lint_run(6)],
            [ci_job(5, "completed", "failure"), lint_job(6)]
          )
      })

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "fail", ac_results: %{"failed_check" => "test", "conclusion" => "failure"}} =
               reload(ctx, run)
    end

    test "test succeeded is a pass naming the judged run", ctx do
      stub_forge(ctx, %{evidence: green()})

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "pass", ac_results: ac} = reload(ctx, run)

      assert ac == %{
               "source" => "ci",
               "evidence_url" => "https://github.com/acme/widgets/actions/runs/5"
             }
    end

    test "only an unrelated workflow succeeded: never a pass", ctx do
      stub_forge(ctx, %{
        evidence: evidence([lint_run(6)], [lint_job(6)])
      })

      run = run!(ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end
  end

  # -- TC-26.4.6.3 --------------------------------------------------------------------------

  describe "TC-26.4.6.3 a workflow edit is refused" do
    test "no verdict, ci_definition_changed, and no evidence read", ctx do
      stage_branch!(ctx, @branch)
      stub_forge(ctx, %{diff: [".github/workflows/ci.yml"], evidence: green()})

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: ac} = reload(ctx, run)
      assert ac == %{"source" => "ci", "ci_unavailable_reason" => "ci_definition_changed"}
      refute_received {:evidence, _}
    end

    test "an unreadable diff is ci_definition_unknown", ctx do
      stage_branch!(ctx, @branch)

      stub_forge(ctx, %{
        compare:
          {:ok,
           %{
             merge_base_sha: @fork_point,
             base_tree_sha: @base_tree,
             diffstat: %{files: 300, changed_lines: 900},
             diff: {:error, {:file_list_truncated, 300}}
           }},
        evidence: green()
      })

      run = run!(ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "ci_definition_unknown"
    end
  end

  # -- AC-26.4.6.3: the change check, once per run ---------------------------------------

  describe "AC-26.4.6.3 the change check is the merge gate's, once per run" do
    setup ctx do
      stage_branch!(ctx, @branch)
      :ok
    end

    test "an old green commit of the base (its own merge base) is empty_change", ctx do
      stub_forge(ctx, %{compare: {:ok, clean([], @sha)}, evidence: green()})

      run = run!(ctx)
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
      stub_forge(ctx, %{compare: {:ok, clean([], @fork_point)}, evidence: green()})

      run = run!(ctx)
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
            evidence([ci_run(5, "in_progress", nil)], [ci_job(5, "in_progress", nil)]),
            green()
          ])
      })

      run = run!(ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert_received {:compare, @sha}
      assert %{change_checked_at: %DateTime{}} = reload(ctx, run)

      # Merged: the comparison now answers an empty diff.
      stub(MockPullRequestSource, :compare, fn @repo, "master", sha ->
        send(ctx.test_pid, {:compare, sha})
        {:ok, clean([], @sha)}
      end)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
      refute_received {:compare, _}
    end

    # Round 4, finding 5: the merge gate's rule, both halves. A head whose tree is the base's
    # is empty however many files its three-dot diff lists.
    test "a head whose tree is the base's is empty_change, whatever the diff lists", ctx do
      stub_forge(ctx, %{tree: @base_tree, evidence: green()})

      run = run!(ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "empty_change"
      assert_received {:commit, @sha}
      refute_received {:evidence, _}
    end

    # Round 4, finding 4: a check that passed but could not be RECORDED is loopctl's database,
    # not a verdict: a wait that leaves the fault streak alone, and the next poll checks again.
    test "a passed check loopctl cannot record is a wait, never internal_error", ctx do
      run = ctx |> run!() |> set_faults!(2)

      # The run row is locked AFTER the run started and before the stamp is written.
      stub_forge(ctx, %{
        compare: fn ->
          lock_run_once!(run)
          {:ok, clean(["lib/widgets/thing.ex"])}
        end,
        evidence: green()
      })

      assert {:snooze, 60} = perform_busy(ctx, run)
      release_run_lock!()

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.change_checked_at == nil
      assert reloaded.ci_forge_faults == 2
      assert_received {:compare, @sha}
      refute_received {:evidence, _}

      # Released: the next poll checks again, records it, and is judged.
      assert :ok = perform(ctx, run)
      assert_received {:compare, @sha}
      assert %{status: "pass", change_checked_at: %DateTime{}} = reload(ctx, run)
    end

    test "a stage row loopctl cannot read is a wait, not a verdict", ctx do
      stub_forge(ctx, %{evidence: green()})
      run = ctx |> run!() |> set_faults!(2)
      hold_table_lock!("story_stages")

      assert {:snooze, 60} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.ci_forge_faults == 2
      refute_received {:credential_asked, _, _}
      refute_received {:compare, _}
    end
  end

  # -- TC-26.4.6.4 --------------------------------------------------------------------------

  describe "TC-26.4.6.4 transient waits, permanent ends, age ends" do
    setup ctx do
      stage_branch!(ctx, @branch)
      :ok
    end

    # #915 round 3, finding 1: one blip must not end a run.
    test "a 502 once then success: a snooze, then a pass", ctx do
      stub_forge(ctx, %{evidence: sequence([{:error, {:github_api_error, 502}}, green()])})

      run = run!(ctx)
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
      stub_forge(ctx, %{compare: {:error, {:github_api_error, 502}}, evidence: green()})
      run = run!(ctx)
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
      run = run!(ctx)
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
      stub_forge(ctx, %{compare: {:error, {:github_rate_limited, 429, 7_200}}, evidence: green()})

      run = run!(ctx)
      assert {:snooze, 3_600} = perform(ctx, run)
    end

    # Review round 1, finding 3(b): the dispatch ledger is loopctl's own database, not the
    # forge. Contention there snoozes without touching the fault streak, and reads nothing.
    test "database contention resolving the branch is not a forge fault", ctx do
      stub_forge(ctx, %{evidence: green()})
      run = ctx |> run!() |> set_faults!(2)
      hold_ledger_lock!()

      assert {:snooze, 60} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "running"
      assert reloaded.ci_forge_faults == 2
      refute_received {:compare, _}
      refute_received {:credential_asked, _, _}
    end

    test "database contention past the age window records database_busy", ctx do
      stub_forge(ctx, %{evidence: green()})
      run = ctx |> run!() |> age!(25 * 60 * 60)
      hold_ledger_lock!()

      assert :ok = perform(ctx, run)

      assert reload(ctx, run).ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "database_busy"
             }
    end

    test "an answered wait resets the fault streak", ctx do
      stub_forge(ctx, %{
        evidence:
          sequence([
            {:error, {:github_unreachable, :timeout}},
            evidence([ci_run(5, "queued", nil)], [ci_job(5, "queued", nil)])
          ])
      })

      run = run!(ctx)
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 1
      assert {:snooze, _} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 0
    end

    test "a 404 records its code at once, and ends the run", ctx do
      stub_forge(ctx, %{compare: {:error, {:github_api_error, 404}}, evidence: green()})

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: ac} = reload(ctx, run)
      assert ac == %{"source" => "ci", "ci_unavailable_reason" => "forge_not_found"}
    end

    test "a missing required check past the age window records ci_wait_exhausted", ctx do
      stub_forge(ctx, %{evidence: evidence([], [])})

      run = ctx |> run!() |> age!(25 * 60 * 60)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "ci_wait_exhausted"
    end

    test "inside the window a missing check waits", ctx do
      stub_forge(ctx, %{evidence: evidence([], [])})

      run = ctx |> run!() |> age!(23 * 60 * 60)
      assert {:snooze, _} = perform(ctx, run)
    end

    test "a transient fault past the age window records forge_unavailable", ctx do
      stub_forge(ctx, %{evidence: {:error, {:github_api_error, 503}}})

      run = ctx |> run!() |> age!(25 * 60 * 60)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "forge_unavailable"
    end

    # #931 finding e: a secondary rate limit is a 403 with a retry-after — waited, at least
    # as long as the forge asked.
    test "a rate limit waits at least the forge's own delay", ctx do
      stub_forge(ctx, %{evidence: {:error, {:github_rate_limited, 403, 600}}})

      run = run!(ctx)
      assert {:snooze, 600} = perform(ctx, run)
      assert reload(ctx, run).status == "running"
    end

    # #931 finding i: the snooze backs off with the run's age instead of a fixed 60s.
    test "the snooze backs off with age, between one and fifteen minutes", ctx do
      stub_forge(ctx, %{
        evidence: evidence([ci_run(5, "queued", nil)], [ci_job(5, "queued", nil)])
      })

      for {age, snooze} <- [{0, 60}, {2 * 60 * 60, 720}, {10 * 60 * 60, 900}] do
        run = ctx |> run!() |> age!(age)
        # The age is measured a moment after it was set: allow that second.
        assert {:snooze, got} = perform(ctx, run)
        assert got in (snooze - 1)..snooze, "age #{age}: snoozed #{got}, expected #{snooze}"
      end
    end
  end

  # -- TC-26.4.6.5 --------------------------------------------------------------------------

  describe "TC-26.4.6.5 an abbreviated SHA is resolved once per run" do
    test "one commit read across polls; the run carries the full SHA and the failing job", ctx do
      stage_branch!(ctx, @branch)

      stub_forge(ctx, %{
        evidence:
          sequence([
            evidence([ci_run(5, "in_progress", nil)], [ci_job(5, "in_progress", nil)]),
            evidence([ci_run(5, "in_progress", nil)], [ci_job(5, "in_progress", nil)]),
            evidence([ci_run(5, "completed", "failure")], [ci_job(5, "completed", "failure")])
          ])
      })

      expect(MockPullRequestSource, :resolve_commit, 1, fn @repo, @short -> {:ok, @sha} end)

      run = run!(ctx, @short)
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
      stage_branch!(ctx, @branch)
      stub_forge(ctx, %{compare: {:error, {:github_api_error, 502}}, evidence: green()})
      expect(MockPullRequestSource, :resolve_commit, 1, fn @repo, @short -> {:ok, @sha} end)

      run = ctx |> run!(@short) |> set_faults!(4)
      assert {:snooze, 900} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.resolved_commit_sha == @sha
      assert reloaded.ci_forge_faults == 5
    end

    test "an unresolvable prefix and an unreadable repository are permanent",
         ctx do
      stage_branch!(ctx, @branch)
      stub_forge(ctx, %{evidence: green()})

      for {status, code} <- [{422, "unresolved_sha"}, {404, "repository_unreadable"}] do
        expect(MockPullRequestSource, :resolve_commit, fn @repo, @short ->
          {:error, {:github_api_error, status}}
        end)

        run = run!(ctx, @short)
        assert :ok = perform(ctx, run)
        assert reload(ctx, run).ac_results == %{"source" => "ci", "ci_unavailable_reason" => code}
      end

      refute_received {:evidence, _}
    end
  end

  # -- every write the runner makes to its run ------------------------------------------------

  # Round 5: every write the worker makes to its own run is bounded, and one it cannot make is
  # a snooze on the database cadence with the run EXACTLY as it was (`updated_at` included):
  # never `internal_error`, never a forge fault counted. Each test locks the run from inside
  # the read just before the write under test; the run is already started and change-checked
  # (`ready!/1`), so that write is the only one the poll makes. Released, the next poll redoes
  # the work and records it.
  describe "a write loopctl cannot make to its run is a wait, and changes nothing" do
    setup ctx do
      stage_branch!(ctx, @branch)
      :ok
    end

    test "starting the run", ctx do
      stub_forge(ctx, %{evidence: green()})
      run = run!(ctx)
      before = snapshot(ctx, run)
      lock_run_once!(run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before
      refute_received {:credential_asked, _, _}

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
    end

    test "retiring a stale run", ctx do
      run = ctx |> run!() |> age!(25 * 60 * 60, false)
      before = snapshot(ctx, run)
      lock_run_once!(run)

      assert {:snooze, 900} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:cancel, :stale_run} = perform(ctx, run)
      assert reload(ctx, run).status == "skipped"
    end

    test "recording the resolved SHA", ctx do
      stub_forge(ctx, %{evidence: green()})
      run = ctx |> run!(@short) |> ready!()
      before = snapshot(ctx, run)

      expect(MockPullRequestSource, :resolve_commit, 2, fn @repo, @short ->
        lock_run_once!(run)
        {:ok, @sha}
      end)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before
      refute_received {:evidence, _}

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert %{status: "pass", resolved_commit_sha: @sha} = reload(ctx, run)
    end

    test "recording a pass", ctx do
      run = ctx |> run!() |> ready!()
      stub_forge(ctx, %{evidence: locking(run, green())})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "pass"
    end

    test "recording a fail", ctx do
      run = ctx |> run!() |> ready!()
      failed = evidence([ci_run(5, "completed", "failure")], [ci_job(5, "completed", "failure")])
      stub_forge(ctx, %{evidence: locking(run, failed)})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).status == "fail"
    end

    # The fault is not counted, and the snooze is the database's, not the streak's backoff.
    test "counting a forge fault", ctx do
      run = ctx |> run!() |> ready!() |> set_faults!(2)
      stub_forge(ctx, %{evidence: locking(run, {:error, {:github_api_error, 503}})})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:snooze, 240} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 3
    end

    test "resetting the fault streak on an answered wait", ctx do
      run = ctx |> run!() |> ready!() |> set_faults!(2)
      pending = evidence([ci_run(5, "queued", nil)], [ci_job(5, "queued", nil)])
      stub_forge(ctx, %{evidence: locking(run, pending)})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert {:snooze, 60} = perform(ctx, run)
      assert reload(ctx, run).ci_forge_faults == 0
    end

    test "recording a no-verdict", ctx do
      run = ctx |> run!() |> ready!()
      stub_forge(ctx, %{evidence: locking(run, {:error, {:github_api_error, 404}})})
      before = snapshot(ctx, run)

      assert {:snooze, 60} = perform_busy(ctx, run)
      assert snapshot(ctx, run) == before

      release_run_lock!()
      assert :ok = perform(ctx, run)

      assert %{status: "error", ac_results: %{"ci_unavailable_reason" => "forge_not_found"}} =
               reload(ctx, run)
    end

    test "recording internal_error after a crash", ctx do
      run = ctx |> run!() |> ready!()

      stub(MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        lock_run_once!(run)
        raise "boom"
      end)

      before = snapshot(ctx, run)

      {result, log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
      assert result == {:snooze, 60}
      assert log =~ "crashed"
      assert busy_warnings(ctx, log) == 1
      assert snapshot(ctx, run) == before

      release_run_lock!()
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
      assert result == {:cancel, :internal_error}
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "internal_error"
    end
  end

  # Review round 1, finding 10: this module's cleanup deletes its own tenant and nothing of
  # another suite's, which shares the test database from another worktree.
  test "cleanup deletes only the tenants it names", ctx do
    other = fixture(:committed_tenant, %{})
    on_exit(fn -> sweep_committed_tenants([other.id]) end)

    # Both calls run unboxed, which gives up this process's AdminRepo checkout.
    :ok = sweep_committed_tenants([Ecto.UUID.generate()])
    checkout_admin()

    assert AdminRepo.get(Loopctl.Tenants.Tenant, other.id)
    assert AdminRepo.get(Loopctl.Tenants.Tenant, ctx.tenant_id)

    :ok = sweep_committed_tenants([other.id])
    checkout_admin()
    refute AdminRepo.get(Loopctl.Tenants.Tenant, other.id)
  end

  # -- plumbing ------------------------------------------------------------------------------

  defp place_thread!(ctx, branch, base_branch) do
    {_raw_key, runner} = fixture(:committed_runner, %{tenant_id: ctx.tenant_id})
    # The fixture's unboxed run gives up this process's AdminRepo checkout; take it back.
    checkout_admin()

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

  defp checkout_admin do
    case Sandbox.checkout(AdminRepo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  # `verification_runs` and `api_keys` reference the tenant without a cascade, so they go
  # before `sweep_committed_tenants/1` can delete it. By this test's tenant id only.
  defp purge(tenant_id) do
    checkout_admin()
    raw = Ecto.UUID.dump!(tenant_id)
    AdminRepo.query!("DELETE FROM verification_runs WHERE tenant_id = $1", [raw])
    AdminRepo.query!("DELETE FROM api_keys WHERE tenant_id = $1", [raw])
  end

  defp set_faults!(run, faults) do
    {1, _} =
      AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id),
        set: [ci_forge_faults: faults]
      )

    run
  end

  # A lock on the dispatch ledger held by another connection until the test ends: the
  # route read waits out its lock_timeout and answers `:busy` (as in the merge gate's own
  # integration test).
  defp hold_ledger_lock!, do: hold_table_lock!("runner_dispatches")

  @run_fields [
    :status,
    :started_at,
    :completed_at,
    :ac_results,
    :ci_forge_faults,
    :resolved_commit_sha,
    :change_checked_at,
    :updated_at
  ]

  # Everything a poll may write on the run, `updated_at` included.
  defp snapshot(ctx, run), do: ctx |> reload(run) |> Map.take(@run_fields)

  # Started and change-checked, so a poll's only write is the one after the forge's answer.
  defp ready!(run) do
    now = DateTime.utc_now()

    {1, _} =
      AdminRepo.update_all(from(r in VerificationRun, where: r.id == ^run.id),
        set: [status: "running", started_at: now, change_checked_at: now]
      )

    run
  end

  # A poll whose write waits out its lock_timeout, answered as a wait: ONE busy warning, naming
  # 55P03 (lock_not_available, so the bounded wait and not the query timeout's lost connection),
  # and no crash. A write that raised instead would reach the rescue arm, log the crash, and
  # try its `internal_error` write against the same lock: a second warning.
  defp perform_busy(ctx, run) do
    {result, log} = ExUnit.CaptureLog.with_log(fn -> perform(ctx, run) end)
    assert busy_warnings(ctx, log) == 1
    refute log =~ "crashed"
    result
  end

  defp busy_warnings(ctx, log) do
    ~r/gave up waiting: tenant_id=#{ctx.tenant_id} error="55P03"/ |> Regex.scan(log) |> length()
  end

  # An evidence answer that locks the run first, once.
  defp locking(run, answer) do
    fn ->
      lock_run_once!(run)
      answer
    end
  end

  # Locks the run on the FIRST call only (`hold_run_lock!/1`), so the poll after
  # `release_run_lock!/0` writes freely.
  defp lock_run_once!(run) do
    unless Process.get(:run_lock), do: Process.put(:run_lock, hold_run_lock!(run))
    :ok
  end

  defp release_run_lock!, do: send(Process.get(:run_lock), :release)

  # A row lock on one verification run, held by another connection until released (or the
  # test ends): the run's next write waits out its lock_timeout.
  defp hold_run_lock!(run) do
    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Sandbox.checkout(AdminRepo, sandbox: false)

        AdminRepo.transaction(fn ->
          AdminRepo.query!("SELECT 1 FROM verification_runs WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(run.id)
          ])

          send(test_pid, :held)

          receive do
            :release -> :ok
          end
        end)

        Sandbox.checkin(AdminRepo)
      end)

    assert_receive :held, 5_000
    on_exit(fn -> send(holder, :release) end)
    holder
  end

  defp hold_table_lock!(table) do
    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
          send(test_pid, :held)

          receive do
            :release -> :ok
          end
        end)

        Sandbox.checkin(Repo)
      end)

    assert_receive :held, 5_000
    on_exit(fn -> send(holder, :release) end)
    holder
  end
end
