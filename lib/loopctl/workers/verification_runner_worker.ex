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

  alias Loopctl.Intake
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

    project =
      from(s in "stories",
        join: p in "projects",
        on: s.project_id == p.id,
        # Schemaless: an uncast UUID string is refused by Postgrex, which crashed every run
        # that had a commit to check before it reached CI (#914).
        where:
          s.id == type(^run.story_id, :binary_id) and
            s.tenant_id == type(^tenant_id, :binary_id),
        select: %{id: type(p.id, :binary_id), repo_url: p.repo_url},
        limit: 1
      )
      |> Loopctl.AdminRepo.one()

    # CI is read from the repository of the project's INTAKE SOURCE, never from its
    # `repo_url`: a tenant can set `repo_url` to any repository, and the read carries the
    # operator's GITHUB_TOKEN, so reading it would disclose another repository's CI.
    ci =
      with %{id: project_id} <- project,
           {:ok, source} <- Intake.source_for_project(tenant_id, project_id) do
        do_ci_check(run, source.repo_full_name)
      else
        nil -> {:error, {:ci_unavailable, "no_project"}}
        {:error, reason} -> {:error, {:ci_unavailable, reason_code(reason)}}
      end

    case ci do
      {:ok, :ci_checked} ->
        :ok

      {:error, {:ci_unavailable, reason}} ->
        # L3 fallback: independent test re-execution
        do_local_test_run(run, project && project.repo_url, reason)

      other ->
        other
    end
  end

  defp do_ci_check(run, repo) do
    case @ci_adapter.get_status(repo, run.commit_sha) do
      {:ok, %{conclusion: "success"} = status} ->
        {:ok, _} = Verification.complete_run(run, "pass", ci_results(status))
        {:ok, :ci_checked}

      {:ok, %{conclusion: "failure"} = status} ->
        {:ok, _} = Verification.complete_run(run, "fail", ci_results(status))
        {:ok, :ci_checked}

      {:ok, %{status: "in_progress"}} ->
        wait_or_give_up(run, 60)

      # A rate limit clears on its own: wait it out rather than clone and re-run the suite,
      # for the forge's delay when it gave a usable one and a floor when it did not.
      {:error, {:github_rate_limited, _status, delay}} ->
        wait_or_give_up(run, rate_limit_snooze(delay))

      {:ok, %{conclusion: other}} ->
        Logger.warning("VerificationRunner: unexpected CI conclusion: #{inspect(other)}")
        {:error, {:ci_unavailable, "unexpected_conclusion"}}

      {:error, reason} ->
        code = reason_code(reason)
        Logger.warning("VerificationRunner: no CI verdict for run #{run.id}: #{code}")
        {:error, {:ci_unavailable, code}}
    end
  end

  @rate_limit_floor_seconds 60

  # How long a run may wait on CI, measured from when it was created: every snooze runs
  # `start_run/1` again, so `started_at` cannot bound it. Past this a queued workflow (an
  # offline self-hosted runner) or a quota that never recovers ends the run as `error`
  # instead of polling GitHub every minute for ever.
  @ci_wait_budget_seconds 24 * 60 * 60

  defp wait_or_give_up(run, snooze) do
    if DateTime.diff(DateTime.utc_now(), run.inserted_at, :second) > @ci_wait_budget_seconds do
      {:ok, _} = Verification.complete_run(run, "error", %{"reason" => "ci_wait_exhausted"})
      {:ok, :ci_checked}
    else
      {:snooze, snooze}
    end
  end

  defp rate_limit_snooze(delay) when is_integer(delay) and delay > 0, do: delay
  defp rate_limit_snooze(_unusable), do: @rate_limit_floor_seconds

  # The reason as a short operator-facing code, and never its terms: those can carry the
  # project's repo_url, which may embed a credential.
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_code(reason) when is_tuple(reason) and is_atom(elem(reason, 0)) do
    case reason do
      {tag, status} when is_integer(status) -> "#{tag}:#{status}"
      {tag, status, _detail} when is_integer(status) -> "#{tag}:#{status}"
      _other -> Atom.to_string(elem(reason, 0))
    end
  end

  defp reason_code(_reason), do: "unknown"

  # The run the verdict came from, so an operator can open the failing workflow.
  defp ci_results(%{url: url}) when is_binary(url) and url != "",
    do: %{"source" => "ci", "url" => url}

  defp ci_results(_status), do: %{"source" => "ci"}

  # L3: independent test re-execution — clone repo, run tests, check results
  defp do_local_test_run(run, nil, ci_reason) do
    {:ok, _} =
      Verification.complete_run(run, "error", %{
        "reason" => "no_repo_url",
        "ci_unavailable_reason" => ci_reason
      })

    :ok
  end

  defp do_local_test_run(run, repo_url, ci_reason) do
    alias Loopctl.Verification.TestRunner

    Logger.info("VerificationRunner: falling back to local test execution for #{run.id}")

    case TestRunner.run_tests(repo_url, run.commit_sha) do
      {:ok, results} ->
        {:ok, _} =
          Verification.complete_run(run, results.status, %{
            "source" => "local_test_runner",
            "ci_unavailable_reason" => ci_reason,
            "tests_run" => results.tests_run,
            "tests_passed" => results.tests_passed,
            "tests_failed" => results.tests_failed
          })

        :ok

      {:error, reason} ->
        Logger.error("VerificationRunner: local test run failed: #{reason_code(reason)}")

        {:ok, _} =
          Verification.complete_run(run, "error", %{
            "local_error" => reason_code(reason),
            "ci_unavailable_reason" => ci_reason
          })

        :ok
    end
  end
end
