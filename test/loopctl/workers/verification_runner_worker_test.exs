defmodule Loopctl.Workers.VerificationRunnerWorkerTest do
  @moduledoc """
  `Loopctl.Workers.VerificationRunnerWorker.perform/1`, for every path that settles WITHOUT a
  story branch: the stale-run age gate (US-36.1), terminal-run re-entry, and the configuration
  refusals of US-26.4.6 that read nothing from the forge, including a tenant named for no
  repository at all. The credential for the (tenant, repository) PAIR is asked only once the
  branch is known, so that refusal and the rescue arm (reached through the credential seam)
  are integration tests.

  The paths that DO read the forge need a branch, which lives on the RLS `Loopctl.Repo`
  (the dispatch ledger and the stage row) while the run and its story live on `AdminRepo` —
  two sandbox owners that cannot see each other's rows. Those are in
  `Loopctl.Workers.VerificationRunnerWorkerIntegrationTest`, on committed rows.

  Every forge read is RECORDED by the stubs below, so a test can refute that one happened.
  """
  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures
  import Mox

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.MockPullRequestSource
  alias Loopctl.MockVerificationCredential
  alias Loopctl.Verification
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.VerificationRun
  alias Loopctl.Workers.VerificationRunnerWorker

  setup :verify_on_exit!

  @sha String.duplicate("a", 40)

  setup do
    test_pid = self()

    for {fun, arity} <- [commit: 2, compare: 3, check_evidence: 3, resolve_commit: 2] do
      stub(MockPullRequestSource, fun, fn_recording(test_pid, {:forge_read, fun}, arity))
    end

    :ok
  end

  defp fn_recording(pid, message, 2),
    do: fn _, _ -> send(pid, message) && {:error, :not_stubbed} end

  defp fn_recording(pid, message, 3),
    do: fn _, _, _ -> send(pid, message) && {:error, :not_stubbed} end

  defp with_credential do
    stub(MockVerificationCredential, :any_for_tenant?, fn _tenant_id -> true end)

    stub(MockVerificationCredential, :for_read, fn _tenant_id, repo ->
      {:ok, %Credential{kind: :operator_token, repo: ForgeRepo.operator(repo)}}
    end)
  end

  defp setup_ctx do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    %{tenant: tenant, project: project, story: story}
  end

  defp run!(ctx, attrs \\ %{commit_sha: @sha}) do
    {:ok, run} = Verification.create_run(ctx.tenant.id, ctx.story.id, attrs)
    run
  end

  defp perform(ctx, run),
    do:
      VerificationRunnerWorker.perform(%Oban.Job{
        args: %{"run_id" => run.id, "tenant_id" => ctx.tenant.id}
      })

  defp reload(ctx, run) do
    {:ok, reloaded} = Verification.get_run(ctx.tenant.id, run.id)
    reloaded
  end

  defp backdate!(run, seconds_ago) do
    stale_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {1, _} =
      AdminRepo.update_all(
        from(r in VerificationRun, where: r.id == ^run.id),
        set: [inserted_at: stale_at]
      )

    run
  end

  defp refute_read, do: refute_received({:forge_read, _})

  describe "stale-run age gate (bounds the backlog burst-drain)" do
    test "a never-started run older than the window is cancelled with no read" do
      ctx = setup_ctx()
      with_credential()
      run = ctx |> run!() |> backdate!(25 * 60 * 60)

      assert {:cancel, :stale_run} = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "skipped"
      assert reloaded.ac_results["reason"] == "stale_run_skipped"
      assert is_integer(reloaded.ac_results["age_seconds"])
      assert reloaded.started_at == nil
      refute_read()
    end

    test "an already-started run past the window is not stale-skipped" do
      ctx = setup_ctx()
      run = run!(ctx, %{})
      {:ok, _} = Verification.start_run(run)
      backdate!(run, 25 * 60 * 60)

      refute match?({:cancel, :stale_run}, perform(ctx, run))
      refute reload(ctx, run).status == "skipped"
    end

    test "a fresh run proceeds through the normal path and starts" do
      ctx = setup_ctx()
      run = run!(ctx, %{})

      assert :ok = perform(ctx, run)
      reloaded = reload(ctx, run)
      refute reloaded.ac_results["reason"] == "stale_run_skipped"
      assert reloaded.started_at
    end
  end

  describe "a run is never reopened (#931 finding h)" do
    test "a run with a disposition is left exactly as it is" do
      ctx = setup_ctx()
      run = run!(ctx)

      {:ok, done} =
        Verification.complete_run(run, "pass", %{"source" => "ci", "evidence_url" => "u"})

      for status <- ~w(pass fail error skipped) do
        {:ok, done} = Verification.update_run(done, %{status: status})
        assert :ok = perform(ctx, done)
        reloaded = reload(ctx, done)
        assert reloaded.status == status
        assert reloaded.started_at == done.started_at
        assert reloaded.ac_results == %{"source" => "ci", "evidence_url" => "u"}
      end

      refute_read()
    end

    test "a started run re-entered keeps its first started_at" do
      ctx = setup_ctx()
      run = run!(ctx, %{})
      first = ~U[2026-09-01 00:00:00.000000Z]
      {:ok, started} = Verification.update_run(run, %{status: "running", started_at: first})

      perform(ctx, started)
      assert reload(ctx, run).started_at == first
    end
  end

  describe "configuration that reads nothing (US-26.4.6)" do
    test "a run with no commit records no_commit_sha" do
      ctx = setup_ctx()
      run = run!(ctx, %{})

      assert :ok = perform(ctx, run)

      assert reload(ctx, run).ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "no_commit_sha"
             }

      refute_read()
    end

    # The pre-existing master bug: the worker's schemaless story/project query passed string
    # UUIDs uncast and crashed every started run before any CI read. This is the same run,
    # through perform/1, reaching the intake-source lookup.
    test "a story whose project has no intake source records no_intake_source (no crash)" do
      ctx = setup_ctx()
      with_credential()
      run = run!(ctx)

      assert :ok = perform(ctx, run)

      reloaded = reload(ctx, run)
      assert reloaded.status == "error"

      assert reloaded.ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "no_intake_source"
             }

      refute_read()
    end

    test "a project with two live sources records ambiguous_intake_source" do
      ctx = setup_ctx()
      with_credential()

      for repo <- ["acme/one", "acme/two"],
          do:
            fixture(:intake_source, %{
              tenant_id: ctx.tenant.id,
              project_id: ctx.project.id,
              repo_full_name: repo,
              required_checks: ["test"]
            })

      run = run!(ctx)
      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "ambiguous_intake_source"
      refute_read()
    end

    test "a pr-mode source with no required checks records no_required_checks (the opt-in)" do
      ctx = setup_ctx()
      with_credential()
      fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})
      run = run!(ctx)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "no_required_checks"
      refute_read()
    end

    # Round 3, finding 3: the order the docs now state. A tenant with no allowlist entry never
    # reaches the required-checks opt-in, so its pr source naming none is credential_unavailable.
    test "an unnamed tenant's pr source naming no checks records credential_unavailable" do
      ctx = setup_ctx()
      fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})
      run = run!(ctx)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "credential_unavailable"
      refute_read()
    end

    # Round 4, finding 2: the order the docs state. The tenant has an entry, for ANOTHER
    # repository: the opt-in is still reached, and the pair is never asked.
    test "a tenant named for another repository whose pr source names none: no_required_checks" do
      ctx = setup_ctx()
      test_pid = self()
      stub(MockVerificationCredential, :any_for_tenant?, fn _tenant_id -> true end)

      stub(MockVerificationCredential, :for_read, fn _tenant_id, _repo ->
        send(test_pid, :pair_asked)
        {:error, :credential_unavailable}
      end)

      fixture(:intake_source, %{tenant_id: ctx.tenant.id, project_id: ctx.project.id})
      run = run!(ctx)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "no_required_checks"
      refute_received :pair_asked
      refute_read()
    end

    # Round 2, finding 9: the tenant is checked before CiTarget reads anything. The story here
    # has NO intake source, so a run that reached CiTarget would record no_intake_source; and
    # the pair would be licensed, so only the tenant check stands in the way.
    test "a tenant named for no repository records credential_unavailable before CiTarget" do
      ctx = setup_ctx()
      test_pid = self()

      stub(MockVerificationCredential, :for_read, fn _tenant_id, repo ->
        send(test_pid, :pair_asked)
        {:ok, %Credential{kind: :operator_token, repo: ForgeRepo.operator(repo)}}
      end)

      run = run!(ctx)
      assert :ok = perform(ctx, run)

      assert reload(ctx, run).ac_results == %{
               "source" => "ci",
               "ci_unavailable_reason" => "credential_unavailable"
             }

      refute_received :pair_asked
      refute_read()
    end

    test "a story never placed on a branch records no_story_branch" do
      ctx = setup_ctx()
      with_credential()

      fixture(:intake_source, %{
        tenant_id: ctx.tenant.id,
        project_id: ctx.project.id,
        required_checks: ["test"]
      })

      run = run!(ctx)

      assert :ok = perform(ctx, run)
      assert reload(ctx, run).ac_results["ci_unavailable_reason"] == "no_story_branch"
      refute_read()
    end
  end

  test "tenant isolation: another tenant's id neither reads nor touches the run" do
    ctx = setup_ctx()
    other = fixture(:tenant)
    run = run!(ctx)

    assert :ok =
             VerificationRunnerWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "tenant_id" => other.id}
             })

    reloaded = reload(ctx, run)
    assert reloaded.status == "pending"
    assert reloaded.started_at == nil
    refute_read()
  end

  # #915 round 3, finding 5 / #931 finding f: the worker branches on the CiBehaviour's declared
  # outcomes only. A GitHub error term in its source is the drift that made a wait terminal.
  test "the worker never matches one adapter's error terms" do
    source = File.read!("lib/loopctl/workers/verification_runner_worker.ex")

    for term <- ~w(github_rate_limited github_api_error github_unreachable no_workflow_runs) do
      refute source =~ term, "the worker matches the adapter term #{term}"
    end

    # And the classification it relies on exists where it should (non-vacuous).
    assert File.read!("lib/loopctl/verification/github_actions.ex") =~ "github_api_error"
  end
end
