defmodule Loopctl.Workers.VerificationRunnerWorker do
  @moduledoc """
  US-26.4.2, redesigned by US-26.4.6 — executes one verification run: records a CI verdict for
  the run's commit by the merge gate's evidence rules, or a short reason why there is none.

  ## What one poll does

  1. A run that already has a disposition (`pass`, `fail`, `error`, `skipped`) is left exactly
     as it is. A job re-entered for it never reopens it or rewrites its `started_at`.
  2. A never-started run older than `verification_max_run_age_seconds` is retired `skipped`
     without any read (the stale-run age gate, below).
  3. The run is started once; `started_at` is written on the first poll only.
  4. The reads are resolved from loopctl's records, in an order that reads nothing from the
     forge until each is settled: the run's commit (`no_commit_sha`), the story's repository,
     required checks and branch (`Loopctl.Verification.CiTarget`; `no_intake_source`,
     `ambiguous_intake_source`, `no_required_checks`, `no_story_branch`), and the credential
     for that tenant AND that repository (`Loopctl.Verification.Credential`;
     `credential_unavailable`).
  5. An abbreviated SHA is resolved to its full id ONCE and persisted on the run
     (`resolved_commit_sha`); every later poll reuses it.
  6. The CI adapter (`Loopctl.Verification.CiBehaviour`) answers one of its declared
     outcomes, and this worker branches on those alone.

  ## Waiting, and what ends a wait

  - `{:wait, :ci_pending}` — a required check still running or not reported. Waits until
    `verification_max_run_age_seconds` from the run's CREATION, then records
    `ci_wait_exhausted`. So a started run IS ended by the age window when it is still waiting
    at the end of it.
  - `{:wait, {:transient, _, _}}` — the forge could not be asked. Counted on the run
    (`ci_forge_faults`); past the merge gate's consecutive-fault bound
    (`Loopctl.Delivery.MergePrecondition.max_consecutive_unevaluated/0`) in a row, or past
    the age window, it records `forge_unavailable`. Any answered forge read resets the count
    to 0: a resolved commit, an answered comparison (so a fault on the evidence read after
    it is the first of a new streak), and a CI read that found a check pending.
  - `{:wait, :database_busy}` — loopctl's own database met contention resolving the story's
    branch (`CiTarget`). Not a forge fault: it neither counts nor resets `ci_forge_faults`.
    Past the age window it records `database_busy`.

  A CI wait, and a database wait, SNOOZES the job, backing off with the run's age: a tenth of
  it, between 60 seconds and 15 minutes, so a run polls about once a minute while its CI is
  fresh and a few times an hour once it has waited for hours. A forge fault backs off with the
  STREAK instead —
  60, 120, 240, 480, then 900 seconds — so the consecutive bound spans about half an hour of
  an unreachable forge rather than a few minutes, and a forge that named its own delay (a rate
  limit) is waited at least that long, up to an hour.

  ## When the local runner is asked

  Only on a FINAL no-verdict the adapter returned for a reason that is neither a refusal
  (`ci_definition_changed`, `ci_definition_unknown`) nor a missing configuration (step 4), and
  only when the commit's full id is known — so never on a wait, and never for a commit whose
  abbreviated SHA could not be resolved. It clones the intake source's repository through the
  same credential seam (`Loopctl.Verification.LocalRunner`). It is disabled by default.

  The local run is bounded twice. Each command it runs has its own wall-clock budget
  (`Loopctl.Verification.TestRunner`), and the worker waits no longer than their sum plus a
  margin (`local_run_timeout_ms/0`) before it kills the run and records `local_timeout` — so
  the run is left with a disposition however the fallback hangs. The job's Oban `timeout/1` is
  above that, as the backstop that frees the `:verification` slot; it can only fire on a hang
  OUTSIDE the local run, and a job it kills is retried, which re-reads the run.

  ## What is recorded

  `ac_results` carries `source`, and on `pass` the judged run's URL, on `fail` the failing
  job's URL and check (`evidence_url`, always inside the tenant's own intake-source
  repository). On no verdict it carries `ci_unavailable_reason`, a short code with no URL and
  no repository name, and after a local fallback its counts or a `local_error` code. No
  exception message and no `inspect/1` output is ever written there; the rescue arm records
  `internal_error` and logs the exception.

  ## Stale-run age gate (US-36.1)

  The `:verification` queue was an unconsumed queue from Epic 26 until US-36.1 registered it,
  so a backlog of `pending` runs and `available` jobs had accumulated. `perform/1` therefore
  retires a NOT-YET-STARTED run older than `verification_max_run_age_seconds` (default 24h)
  as `"skipped"` (`reason: "stale_run_skipped"`) and cancels the job with no read and no
  clone. `"skipped"`, not `"error"`: a deliberate non-execution carries no fault and no
  verification signal (see `Loopctl.Verification.complete_run/3`).

  No run status here ever touches `stories.verified_status`: the chain-of-custody verify action
  is entirely separate (`LoopctlWeb.StoryVerificationController`).
  """

  use Oban.Worker, queue: :verification, max_attempts: 3

  require Logger

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Verification
  alias Loopctl.Verification.CiTarget
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.TestRunner

  @ci_adapter Application.compile_env(:loopctl, :ci_adapter, Loopctl.Verification.GitHubActions)

  # 24h: a day-old commit's CI status carries no verification signal worth waiting for, and
  # the accumulated pre-registration backlog is exactly this class of run.
  @default_max_run_age_seconds 24 * 60 * 60

  @terminal ~w(pass fail error skipped)

  @min_snooze_seconds 60
  @max_snooze_seconds 15 * 60
  @max_forge_delay_seconds 60 * 60

  # The local run's command budgets (`TestRunner.max_run_seconds/0`) plus a minute for what is
  # not a command: the egress guard's DNS lookup and removing the clone.
  @local_run_margin_ms 60_000
  # The CI reads and the database writes that precede and follow a local run, each bounded by
  # its own client timeout; five minutes above the local bound is ample for all of them.
  @job_margin_ms 5 * 60_000

  # Above the local bound whichever is larger, the configured one or the runner's own, so the
  # job is never killed while a local run is still inside its budgets.
  @impl Oban.Worker
  def timeout(_job),
    do: max(local_run_timeout_ms(), default_local_run_timeout_ms()) + @job_margin_ms

  @doc """
  How long the worker waits for a local run before killing it and recording `local_timeout`:
  every command budget of the runner plus a margin, unless `config/test.exs` shortens it.
  """
  @spec local_run_timeout_ms() :: pos_integer()
  def local_run_timeout_ms do
    Application.get_env(
      :loopctl,
      :verification_local_run_timeout_ms,
      default_local_run_timeout_ms()
    )
  end

  defp default_local_run_timeout_ms,
    do: :timer.seconds(TestRunner.max_run_seconds()) + @local_run_margin_ms

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "tenant_id" => tenant_id}}) do
    case Verification.get_run(tenant_id, run_id) do
      # A run with a disposition is never reopened (#931 finding h).
      {:ok, %{status: status}} when status in @terminal ->
        :ok

      {:ok, run} ->
        process_run(run, tenant_id)

      {:error, :not_found} ->
        Logger.warning("VerificationRunner: run #{run_id} not found")
        :ok
    end
  end

  defp process_run(run, tenant_id) do
    if stale_run?(run) do
      skip_stale_run(run)
    else
      case Verification.start_run(run) do
        {:ok, started} -> execute(started, tenant_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Un-started only: a started run that ages out while waiting is ended by `settle/1` with
  # the reason it was waiting for, not retired as a skip.
  defp stale_run?(%{started_at: started_at}) when not is_nil(started_at), do: false

  defp stale_run?(%{inserted_at: inserted_at}) when not is_nil(inserted_at),
    do: expired?(inserted_at)

  defp stale_run?(_run), do: false

  defp skip_stale_run(run) do
    age_seconds = age(run)

    Logger.info(
      "VerificationRunner: skipping stale run #{run.id} for story #{run.story_id} " <>
        "(age #{age_seconds}s > #{max_run_age_seconds()}s) — no CI call / repo clone"
    )

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

  defp execute(run, tenant_id) do
    Logger.info("VerificationRunner: executing run #{run.id} for story #{run.story_id}")
    run |> verify(tenant_id) |> settle()
  rescue
    error ->
      # The exception goes to the LOG only: ac_results is tenant-visible and records a code.
      Logger.error(
        "VerificationRunner: run #{run.id} crashed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:ok, _} = no_verdict(run, "internal_error")
      # The run has its disposition, so a retry would only find it terminal (#931 finding g).
      {:cancel, :internal_error}
  end

  # -- resolving what to read -------------------------------------------------------------

  defp verify(run, tenant_id) do
    ctx = %{run: run, repo: nil, sha: nil, credential: nil}

    with {:ok, sha} <- commit_sha(run),
         {:ok, target} <- CiTarget.gather(tenant_id, run.story_id),
         {:ok, credential} <- credential(tenant_id, target.repo),
         ctx = %{ctx | credential: credential, repo: target.repo},
         {:ok, run, full} <- full_sha(run, target.repo, sha, credential) do
      request = Map.merge(target, %{sha: full, credential: credential})
      {%{ctx | run: run, sha: full}, @ci_adapter.verdict(request)}
    else
      {:resolved, run, outcome} -> {%{ctx | run: run}, outcome}
      outcome -> {ctx, outcome}
    end
  end

  defp commit_sha(%{commit_sha: sha}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp commit_sha(_run), do: {:unconfigured, "no_commit_sha"}

  # Asked for the (tenant, repository) pair: an allowlisted tenant gets no credential for a
  # repository it enrolled that the operator did not name with it.
  defp credential(tenant_id, repo) do
    case Credential.for_read(tenant_id, repo) do
      {:ok, %Credential{} = credential} -> {:ok, credential}
      {:error, :credential_unavailable} -> {:unconfigured, "credential_unavailable"}
    end
  end

  # AC-26.4.6.7: a full id is used as it is; an abbreviated one is resolved ONCE and the
  # answer persisted, so no later poll of this run reads the commit again. The resolution is
  # an ANSWERED forge read, so it also ends any fault streak.
  defp full_sha(%{resolved_commit_sha: full} = run, _repo, _sha, _credential)
       when is_binary(full),
       do: {:ok, run, full}

  defp full_sha(run, repo, sha, credential) do
    if Loopctl.GitSha.valid?(sha) do
      {:ok, run, sha}
    else
      case @ci_adapter.resolve_commit(repo, sha, credential) do
        {:ok, full} ->
          {:ok, run} =
            Verification.record_poll(run, %{resolved_commit_sha: full, ci_forge_faults: 0})

          {:ok, run, full}

        outcome ->
          {:resolved, run, outcome}
      end
    end
  end

  # -- settling one outcome ----------------------------------------------------------------

  defp settle({%{run: run}, {:pass, evidence}}) do
    {:ok, _} =
      Verification.complete_run(run, "pass", %{
        "source" => "ci",
        "evidence_url" => evidence.url
      })

    :ok
  end

  defp settle({%{run: run}, {:fail, evidence}}) do
    {:ok, _} =
      Verification.complete_run(run, "fail", %{
        "source" => "ci",
        "evidence_url" => evidence.url,
        "failed_check" => evidence.check,
        "conclusion" => evidence.conclusion
      })

    :ok
  end

  defp settle({%{run: run} = ctx, {:wait, :ci_pending}}) do
    if expired?(run.inserted_at) do
      final(ctx, "ci_wait_exhausted")
    else
      # The forge answered: a fault streak, if any, is over.
      {:ok, _} = reset_faults(run)
      {:snooze, snooze_seconds(run)}
    end
  end

  defp settle({%{run: run} = ctx, {:wait, {:transient, retry_after, answered}}}) do
    # An earlier read of this poll was answered: the previous streak ended there.
    faults = if(answered, do: 0, else: run.ci_forge_faults || 0) + 1

    if faults > MergePrecondition.max_consecutive_unevaluated() or expired?(run.inserted_at) do
      final(ctx, "forge_unavailable")
    else
      {:ok, _} = Verification.record_poll(run, %{ci_forge_faults: faults})
      {:snooze, faults |> fault_backoff_seconds() |> max(forge_delay(retry_after))}
    end
  end

  # loopctl's own database, not the forge: waited on the CI cadence, never counted as a fault.
  defp settle({%{run: run} = ctx, {:wait, :database_busy}}) do
    if expired?(run.inserted_at),
      do: final(ctx, "database_busy"),
      else: {:snooze, snooze_seconds(run)}
  end

  # A refusal and a missing configuration record no verdict and never fall back.
  defp settle({%{run: run}, {kind, code}}) when kind in [:refused, :unconfigured] do
    {:ok, _} = no_verdict(run, code)
    :ok
  end

  defp settle({ctx, {:no_verdict, code}}), do: final(ctx, code)

  defp reset_faults(%{ci_forge_faults: 0} = run), do: {:ok, run}
  defp reset_faults(run), do: Verification.record_poll(run, %{ci_forge_faults: 0})

  # A final no-verdict for a reason CI could not overcome: the local runner is asked when the
  # commit's full id and the repository are known, and never otherwise.
  defp final(%{run: run, repo: repo, sha: sha, credential: credential}, code)
       when is_binary(repo) and is_binary(sha) and not is_nil(credential) do
    Logger.info("VerificationRunner: run #{run.id} has no CI verdict (#{code}); local fallback")

    case run_local(clone_url(repo), sha, credential) do
      {:ok, results} ->
        {:ok, _} =
          Verification.complete_run(run, results.status, %{
            "source" => "local_test_runner",
            "ci_unavailable_reason" => code,
            "tests_run" => results.tests_run,
            "tests_passed" => results.tests_passed,
            "tests_failed" => results.tests_failed
          })

      {:error, reason} ->
        {:ok, _} =
          Verification.complete_run(run, "error", %{
            "source" => "ci",
            "ci_unavailable_reason" => code,
            "local_error" => local_error(reason)
          })
    end

    :ok
  end

  defp final(%{run: run}, code) do
    {:ok, _} = no_verdict(run, code)
    :ok
  end

  defp no_verdict(run, code),
    do:
      Verification.complete_run(run, "error", %{"source" => "ci", "ci_unavailable_reason" => code})

  # The local run, in a task the worker kills at `local_run_timeout_ms/0`. The runner's own
  # command budgets end it first; this is what guarantees a disposition if something outside
  # them hangs. The task never raises into this process (the link would take the job down
  # before the run is recorded): an exception becomes an error the run records.
  defp run_local(url, sha, credential) do
    runner = local_runner()

    task =
      Task.async(fn ->
        try do
          runner.run_tests(url, sha, credential)
        rescue
          error ->
            Logger.error("VerificationRunner: local run crashed: " <> Exception.message(error))
            {:error, :local_runner_crashed}
        catch
          kind, reason ->
            Logger.error("VerificationRunner: local run #{kind}: #{inspect(reason)}")
            {:error, :local_runner_crashed}
        end
      end)

    case Task.yield(task, local_run_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out -> {:error, :local_timeout}
    end
  end

  defp local_error(:runner_disabled), do: "runner_disabled"
  defp local_error(:local_timeout), do: "local_timeout"
  defp local_error(:invalid_commit_sha), do: "invalid_commit_sha"
  defp local_error(:invalid_repo_url), do: "invalid_repo_url"
  defp local_error({:clone_failed, _output}), do: "clone_failed"
  defp local_error({:fetch_failed, _output}), do: "fetch_failed"
  defp local_error({:checkout_failed, _output}), do: "checkout_failed"
  defp local_error(_other), do: "local_runner_error"

  # Built from the intake source's `owner/name` only (validated `Loopctl.Intake.Source`
  # format), so the clone can only ever reach the repository the CI read judged.
  defp clone_url(repo), do: "https://github.com/" <> repo <> ".git"

  defp local_runner do
    Application.get_env(:loopctl, :verification_local_runner, Loopctl.Verification.TestRunner)
  end

  # A tenth of the run's age, between one and fifteen minutes (#931 finding i).
  defp snooze_seconds(run) do
    run |> age() |> div(10) |> max(@min_snooze_seconds) |> min(@max_snooze_seconds)
  end

  # The Nth forge fault in a row: 60 seconds doubled per fault, capped at fifteen minutes.
  defp fault_backoff_seconds(faults),
    do: min(@min_snooze_seconds * Integer.pow(2, faults - 1), @max_snooze_seconds)

  defp forge_delay(seconds) when is_integer(seconds) and seconds > 0,
    do: min(seconds, @max_forge_delay_seconds)

  defp forge_delay(_none), do: 0

  defp age(%{inserted_at: %DateTime{} = at}), do: DateTime.diff(DateTime.utc_now(), at, :second)
  defp age(_run), do: 0

  defp expired?(%DateTime{} = inserted_at),
    do: DateTime.diff(DateTime.utc_now(), inserted_at, :second) > max_run_age_seconds()

  defp expired?(_inserted_at), do: false
end
