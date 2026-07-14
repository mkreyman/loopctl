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
end
