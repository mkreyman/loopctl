defmodule Loopctl.Workers.VerificationRunnerWorker do
  @moduledoc """
  US-26.4.2 — Processes verification runs.

  Dequeues pending runs, fetches the commit SHA, and checks CI status
  via the configured CI adapter (GitHub Actions by default). Falls back
  to marking as manual-review-needed if CI is unavailable.

  ## Stale-run age gate (US-36.1)

  The `:verification` queue was registered by US-36.1 after being an unconsumed
  (dead) queue since Epic 26 — `Loopctl.Verification.create_run_and_enqueue/3` has
  been atomically inserting a `pending` run + an `available` Oban job all along, but
  with no consumer those jobs accumulated (and `Oban.Plugins.Pruner` prunes only
  TERMINAL jobs, so the `available` backlog was never pruned). The moment a consumer
  registers, Oban drains that entire backlog at once. Width 1 bounds the RATE, not
  the total volume — and each drained job would otherwise call a GitHub Actions API
  and, on CI-unavailable, clone the repo and run its suite against a possibly-stale
  SHA (`Loopctl.Verification.TestRunner`), writing pass/fail completions for
  long-idle runs. That work is pointless for a run enqueued days ago.

  `perform/1` therefore age-gates on the run's `inserted_at`, but ONLY for a run that
  has not yet started (`started_at == nil`): a not-yet-started run older than
  `verification_max_run_age_seconds` (default 24h, config-tunable) is completed with
  the terminal `"skipped"` disposition (`reason: "stale_run_skipped"`) and the job is
  `:cancel`led WITHOUT any CI call or repo clone. This bounds the one-time drain to
  cheap DB writes: a genuinely fresh run (enqueued moments ago by the live
  `POST /stories/:id/verifications` action) is always inside the window and runs
  normally; a stale accumulated backlog job is retired without side effects. The
  window is retunable via `config :loopctl, :verification_max_run_age_seconds`.

  ### Why `"skipped"`, not `"error"`, and why the `started_at == nil` guard

  A stale-skipped run carries NO verification signal and NO fault — retiring it as
  `"error"` would conflate a deliberate skip with a genuine failure, so it gets the
  dedicated `"skipped"` disposition (see `Loopctl.Verification.complete_run/3`).
  Restricting the gate to not-yet-started runs keeps it a pure backlog-drain bound: it
  can never complete an in-flight run mid-execution. In particular a run that has
  begun and is snoozing on `in_progress` CI (`{:snooze, 60}`) is `status: "running"`
  with `started_at` set, so even if its `inserted_at` ages past the window across
  snoozes it is NOT killed mid-flight — it stays on the normal path until CI resolves.

  Neither `"skipped"` nor `"error"` ever touches `stories.verified_status` — the run
  status is observational only; the chain-of-custody verify action is entirely
  separate (`LoopctlWeb.StoryVerificationController`). This gate is therefore fail-safe
  for L3 custody: it cannot cause a run to falsely PASS, nor mark a story verified.
  """

  use Oban.Worker, queue: :verification, max_attempts: 3

  require Logger

  alias Loopctl.Verification

  @ci_adapter Application.compile_env(:loopctl, :ci_adapter, Loopctl.Verification.GitHubActions)

  # Default staleness window for a verification run. A run whose `inserted_at` is
  # older than this is skipped (see the "Stale-run age gate" moduledoc section).
  # 24h: a day-old commit's CI status / freshly-cloned test suite carries no
  # verification signal, and the accumulated pre-registration backlog is exactly
  # this class of run.
  @default_max_run_age_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "tenant_id" => tenant_id}}) do
    case Verification.get_run(tenant_id, run_id) do
      {:ok, run} ->
        process_run(run, tenant_id)

      {:error, :not_found} ->
        Logger.warning("VerificationRunner: run #{run_id} not found")
        :ok
    end
  end

  # Age-gate first (see the "Stale-run age gate" moduledoc section): a run older than
  # the freshness window is retired without ever starting, so no CI call / repo clone.
  defp process_run(run, tenant_id) do
    if stale_run?(run) do
      skip_stale_run(run)
    else
      case Verification.start_run(run) do
        {:ok, started} -> execute_verification(started, tenant_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A run is stale when it has NOT yet started (`started_at == nil`) AND was inserted
  # more than `max_run_age_seconds/0` ago. Uses `inserted_at` (set atomically with the
  # Oban job in `create_run_and_enqueue/3`), so age reflects enqueue time regardless of
  # how long the job sat unconsumed. The `started_at == nil` guard scopes the gate to
  # the un-started backlog it exists to drain: an already-started run (e.g. one snoozing
  # on in_progress CI) is never killed mid-flight even if it ages past the window.
  defp stale_run?(%{started_at: started_at}) when not is_nil(started_at), do: false

  defp stale_run?(%{inserted_at: inserted_at}) when not is_nil(inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) > max_run_age_seconds()
  end

  defp stale_run?(_run), do: false

  defp skip_stale_run(run) do
    age_seconds = DateTime.diff(DateTime.utc_now(), run.inserted_at, :second)

    Logger.info(
      "VerificationRunner: skipping stale run #{run.id} for story #{run.story_id} " <>
        "(age #{age_seconds}s > #{max_run_age_seconds()}s) — no CI call / repo clone"
    )

    # `"skipped"`, NOT `"error"`: a deliberate non-execution carries no fault and no
    # verification signal (see the moduledoc + Verification.complete_run/3).
    {:ok, _} =
      Verification.complete_run(run, "skipped", %{
        "reason" => "stale_run_skipped",
        "age_seconds" => age_seconds
      })

    {:cancel, :stale_run}
  end

  defp max_run_age_seconds do
    Application.get_env(:loopctl, :verification_max_run_age_seconds, @default_max_run_age_seconds)
  end

  defp execute_verification(run, tenant_id) do
    Logger.info("VerificationRunner: executing run #{run.id} for story #{run.story_id}")

    if run.commit_sha do
      check_ci_status(run, tenant_id)
    else
      {:ok, _} = Verification.complete_run(run, "error", %{"reason" => "no_commit_sha"})
      :ok
    end
  rescue
    error ->
      Logger.error("VerificationRunner: run #{run.id} failed: #{Exception.message(error)}")
      Verification.complete_run(run, "error", %{"error" => Exception.message(error)})
      {:error, Exception.message(error)}
  end

  defp check_ci_status(run, tenant_id) do
    import Ecto.Query

    repo_url =
      from(s in "stories",
        join: p in "projects",
        on: s.project_id == p.id,
        where: s.id == ^run.story_id and s.tenant_id == ^tenant_id,
        select: p.repo_url,
        limit: 1
      )
      |> Loopctl.AdminRepo.one()

    if repo_url do
      case do_ci_check(run, repo_url) do
        {:ok, :ci_checked} ->
          :ok

        {:error, :ci_unavailable} ->
          # L3 fallback: independent test re-execution
          do_local_test_run(run, repo_url)

        other ->
          other
      end
    else
      {:ok, _} = Verification.complete_run(run, "error", %{"reason" => "no_repo_url"})
      :ok
    end
  end

  defp do_ci_check(run, repo_url) do
    case @ci_adapter.get_status(repo_url, run.commit_sha) do
      {:ok, %{conclusion: "success"}} ->
        {:ok, _} = Verification.complete_run(run, "pass", %{"source" => "ci"})
        {:ok, :ci_checked}

      {:ok, %{conclusion: "failure"}} ->
        {:ok, _} = Verification.complete_run(run, "fail", %{"source" => "ci"})
        {:ok, :ci_checked}

      {:ok, %{status: "in_progress"}} ->
        {:snooze, 60}

      {:ok, %{conclusion: other}} ->
        Logger.warning("VerificationRunner: unexpected CI conclusion: #{inspect(other)}")
        {:error, :ci_unavailable}

      {:error, _reason} ->
        {:error, :ci_unavailable}
    end
  end

  # L3: independent test re-execution — clone repo, run tests, check results
  defp do_local_test_run(run, repo_url) do
    alias Loopctl.Verification.TestRunner

    Logger.info("VerificationRunner: falling back to local test execution for #{run.id}")

    case TestRunner.run_tests(repo_url, run.commit_sha) do
      {:ok, results} ->
        {:ok, _} =
          Verification.complete_run(run, results.status, %{
            "source" => "local_test_runner",
            "tests_run" => results.tests_run,
            "tests_passed" => results.tests_passed,
            "tests_failed" => results.tests_failed
          })

        :ok

      {:error, reason} ->
        Logger.error("VerificationRunner: local test run failed: #{inspect(reason)}")
        {:ok, _} = Verification.complete_run(run, "error", %{"local_error" => inspect(reason)})
        :ok
    end
  end
end
