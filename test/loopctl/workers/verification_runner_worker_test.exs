defmodule Loopctl.Workers.VerificationRunnerWorkerTest do
  @moduledoc """
  US-36.1: the stale-run age gate that bounds the one-time backlog drain when the
  previously-dead `:verification` queue registers a consumer.

  Since Epic 26, `Verification.create_run_and_enqueue/3` has inserted a `pending`
  run + an `available` Oban job atomically, but with no consumer the jobs
  accumulated (and Pruner prunes only TERMINAL jobs). The moment a consumer
  registers, Oban drains that whole backlog. Each drained job would otherwise call
  the CI adapter and, on CI-unavailable, clone the repo and run its suite against a
  possibly-stale SHA. The age gate skips a run older than the freshness window
  WITHOUT any CI call or repo clone, so the drain costs only cheap DB writes.

  These tests exercise `perform/1` directly (rather than via the queue) so a run's
  `inserted_at` can be backdated to simulate the pre-registration backlog — the
  scenario the topology test's fresh :manual-mode inserts never covered.
  """
  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Verification
  alias Loopctl.Verification.VerificationRun
  alias Loopctl.Workers.VerificationRunnerWorker

  defp setup_ctx do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    %{tenant: tenant, story: story}
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

  describe "stale-run age gate (bounds the backlog burst-drain)" do
    test "a run older than the freshness window is cancelled without starting (no CI call / repo clone)" do
      %{tenant: tenant, story: story} = setup_ctx()

      # A run WITH a commit_sha and a project repo_url would, if it reached
      # execute_verification, make a real CI call and clone the repo. Backdating it
      # beyond the 24h default window must short-circuit BEFORE start_run, so none
      # of that happens.
      {:ok, run} =
        Verification.create_run(tenant.id, story.id, %{commit_sha: String.duplicate("a", 40)})

      backdate!(run, 25 * 60 * 60)

      job = %Oban.Job{args: %{"run_id" => run.id, "tenant_id" => tenant.id}}

      # {:cancel, _} tells Oban to discard the job (no retry) — the stale backlog
      # job is retired, not re-attempted.
      assert {:cancel, :stale_run} = VerificationRunnerWorker.perform(job)

      {:ok, reloaded} = Verification.get_run(tenant.id, run.id)
      # A deliberate skip, NOT an "error" — a stale-skipped run carries no fault and no
      # verification signal, so it gets the dedicated non-error disposition.
      assert reloaded.status == "skipped"
      refute reloaded.status == "error"
      assert reloaded.ac_results["reason"] == "stale_run_skipped"
      assert is_integer(reloaded.ac_results["age_seconds"])

      # started_at stays nil — proof the gate short-circuited before start_run and
      # therefore before any CI adapter call or repo clone.
      assert reloaded.started_at == nil
    end

    test "an already-STARTED run past the window is NOT stale-skipped (gate is un-started-only)" do
      %{tenant: tenant, story: story} = setup_ctx()

      # A run that has already begun (e.g. one snoozing on in_progress CI): started_at
      # is set. Even if it ages past the window, the gate must NOT retire it mid-flight
      # — the age gate exists only to drain the never-started backlog. No commit_sha so
      # the normal path resolves hermetically (no CI call), a proxy for "it ran".
      {:ok, run} = Verification.create_run(tenant.id, story.id)

      {:ok, _} = Verification.start_run(run)
      backdate!(run, 25 * 60 * 60)

      {:ok, started} = Verification.get_run(tenant.id, run.id)
      assert started.started_at

      job = %Oban.Job{args: %{"run_id" => run.id, "tenant_id" => tenant.id}}

      # It does NOT short-circuit as {:cancel, :stale_run}; it re-enters the normal
      # path (which, with no commit_sha, completes as error `no_commit_sha` — the point
      # is that it was NOT retired as a stale skip).
      refute match?({:cancel, :stale_run}, VerificationRunnerWorker.perform(job))

      {:ok, reloaded} = Verification.get_run(tenant.id, run.id)
      refute reloaded.status == "skipped"
      refute reloaded.ac_results["reason"] == "stale_run_skipped"
    end
  end

  describe "fresh runs are unaffected (gate is not overly aggressive)" do
    test "a run inside the freshness window proceeds through the normal path, not the stale skip" do
      %{tenant: tenant, story: story} = setup_ctx()

      # No commit_sha: execute_verification completes as error `no_commit_sha`
      # without ever calling CI — a hermetic proxy for "the normal path ran".
      {:ok, run} = Verification.create_run(tenant.id, story.id)

      job = %Oban.Job{args: %{"run_id" => run.id, "tenant_id" => tenant.id}}

      assert :ok = VerificationRunnerWorker.perform(job)

      {:ok, reloaded} = Verification.get_run(tenant.id, run.id)
      # It was NOT skipped as stale...
      refute reloaded.ac_results["reason"] == "stale_run_skipped"
      # ...and it DID start (normal path), which the stale gate skips.
      assert reloaded.started_at
    end
  end

  describe "the CI verdict (#913)" do
    @sha "0123456789abcdef0123456789abcdef01234567"

    defp ci_run(ctx) do
      %{tenant: tenant, story: story} = ctx

      {1, _} =
        AdminRepo.update_all(
          from(p in "projects",
            join: e in "epics",
            on: e.project_id == p.id,
            join: s in "stories",
            on: s.epic_id == e.id,
            where: s.id == type(^story.id, :binary_id)
          ),
          set: [repo_url: "https://github.com/mkreyman/infra"]
        )

      {:ok, run} = Verification.create_run(tenant.id, story.id, %{commit_sha: @sha})
      {run, %Oban.Job{args: %{"run_id" => run.id, "tenant_id" => tenant.id}}}
    end

    defp stub_ci(fun), do: Req.Test.stub(Loopctl.Delivery.GitHubPullRequestSource, fun)

    test "a failing run is recorded with the URL of the workflow that failed" do
      stub_ci(fn conn ->
        runs =
          if conn.query_params["event"] == "push",
            do: [
              %{
                "id" => 7,
                "path" => ".github/workflows/ci.yml",
                "event" => "push",
                "head_branch" => "main",
                "head_sha" => @sha,
                "status" => "completed",
                "conclusion" => "failure",
                "html_url" => "https://github.com/mkreyman/infra/actions/runs/7"
              }
            ],
            else: []

        Req.Test.json(conn, %{"total_count" => length(runs), "workflow_runs" => runs})
      end)

      {run, job} = ci_run(setup_ctx())
      assert :ok = VerificationRunnerWorker.perform(job)

      {:ok, done} = Verification.get_run(run.tenant_id, run.id)
      assert done.status == "fail"
      assert done.ac_results["url"] == "https://github.com/mkreyman/infra/actions/runs/7"
    end

    test "a rate limit is waited out, not answered with a clone and a local test run" do
      stub_ci(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.send_resp(429, "{}")
      end)

      {_run, job} = ci_run(setup_ctx())
      assert {:snooze, 120} = VerificationRunnerWorker.perform(job)
    end

    test "a rate limit with no usable delay still waits, for a floor" do
      stub_ci(&Plug.Conn.send_resp(&1, 429, "{}"))

      {_run, job} = ci_run(setup_ctx())
      assert {:snooze, 60} = VerificationRunnerWorker.perform(job)
    end

    test "a refused read records a code, never the terms of the reason" do
      stub_ci(&Plug.Conn.send_resp(&1, 403, "{}"))

      {run, job} = ci_run(setup_ctx())
      assert :ok = VerificationRunnerWorker.perform(job)

      {:ok, done} = Verification.get_run(run.tenant_id, run.id)
      assert done.ac_results["ci_unavailable_reason"] == "github_api_error:403"
    end

    test "no CI evidence falls back AND records why, so a missing token scope is visible" do
      stub_ci(&Req.Test.json(&1, %{"total_count" => 0, "workflow_runs" => []}))

      {run, job} = ci_run(setup_ctx())
      assert :ok = VerificationRunnerWorker.perform(job)

      {:ok, done} = Verification.get_run(run.tenant_id, run.id)
      assert done.ac_results["ci_unavailable_reason"] == "no_ci_evidence"
    end
  end
end
