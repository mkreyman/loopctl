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
     forge until each is settled: the run's commit (`no_commit_sha`); whether the tenant is
     named for ANY repository (`Loopctl.Verification.Credential.any_for_tenant?/1`;
     `credential_unavailable`), before any read of the story, so an unnamed tenant costs no
     database read; the story's repository, required checks and branch
     (`Loopctl.Verification.CiTarget`; `no_intake_source`, `ambiguous_intake_source`,
     `no_required_checks`, `no_story_branch`); and the credential for that tenant AND that
     repository (`Credential.for_read/2`; `credential_unavailable`), before any forge read. So
     a tenant with no allowlist entry at all records `credential_unavailable` even when its
     source names no required checks; a tenant with an entry, whose pr source names none,
     records `no_required_checks` whichever repository its entry names.
  5. An abbreviated SHA is resolved to its full id ONCE and persisted on the run
     (`resolved_commit_sha`); every later poll reuses it.
  6. THE CHANGE CHECK (`CiBehaviour.check_change/1`), ONCE per run, by the thread merge
     gate's own change rules: an empty change (the commit's tree is the base's, or its
     three-dot diff with the base lists no file) is `empty_change`, a change to CI definitions
     `ci_definition_changed` (or `ci_definition_unknown`). Passing it stamps
     `change_checked_at` on the run, and a stamped run is never compared again, so a merge
     that lands during the CI wait — which empties that diff — cannot turn a checked commit
     into a refused one. Story verification runs BEFORE the merge: the run is enqueued by the
     custody verify call (`LoopctlWeb.StoryVerificationController`), and the merge gate allows
     nothing until the story is `verified` (`Loopctl.Delivery.MergePrecondition`, custody).
  7. The CI adapter (`Loopctl.Verification.CiBehaviour`) answers one of its declared
     outcomes, and this worker branches on those alone.

  ## Waiting, and what ends a wait

  - `{:wait, :ci_pending}` — a required check still running or not reported. Waits until
    `verification_max_run_age_seconds` from the run's CREATION, then records
    `ci_wait_exhausted`. So a started run IS ended by the age window when it is still waiting
    at the end of it.
  - `{:wait, {:transient, _}}` — the forge could not be asked. Every poll that ends this
    way counts one on the run (`ci_forge_faults`), whichever of its reads faulted; past the
    merge gate's consecutive-fault bound
    (`Loopctl.Delivery.MergePrecondition.max_consecutive_unevaluated/0`), or past the age
    window, it records `forge_unavailable`. Only a poll that ends in a CI ANSWER resets the
    count to 0, and the only answer that leaves the run open is a pending check. A read that
    was answered earlier in a faulting poll resets nothing, or a persistent fault on a later
    read would never reach the bound; nor does resolving an abbreviated SHA, which happens
    once per run.
  - `{:wait, :database_busy}` — loopctl's own database met contention resolving the story's
    branch (`CiTarget`), or writing the run: every write this worker makes to it (starting it,
    the resolved SHA, the change-check stamp, the fault count, a disposition) is bounded
    (`Loopctl.Verification`, "Bounded writes"), and one that could not be made leaves the run
    exactly as it was, so the next poll redoes the work. Not a forge fault: it neither counts
    nor resets `ci_forge_faults`. Past the age window, a wait resolving the branch or
    recording the resolved SHA or the stamp records `database_busy`; a write that fails
    while the run starts or the poll settles (a verdict, a fault count, a disposition) only
    snoozes.

  A CI wait, and a database wait, SNOOZES the job, backing off with the run's age: a tenth of
  it, between 60 seconds and 15 minutes, so a run polls about once a minute while its CI is
  fresh and a few times an hour once it has waited for hours. A forge fault backs off with the
  STREAK instead — 60, 120, 240, 480, then 900 seconds — so the consecutive bound spans about
  half an hour of an unreachable forge rather than a few minutes, and a forge that named its
  own delay (a rate limit) is waited at least that long, up to an hour.

  ## What is recorded

  `ac_results` carries `source`, and on `pass` the judged run's URL, on `fail` the failing
  job's URL and check (`evidence_url`, always inside the tenant's own intake-source
  repository). On no verdict it carries `ci_unavailable_reason`, a short code with no URL and
  no repository name, and nothing else: a final no-verdict ends the run. No exception message
  and no `inspect/1` output is ever written there; the rescue arm records `internal_error`
  and logs the exception. A disposition is one `UPDATE` (`Verification.complete_run/3`), so a
  write that fails leaves none of it.

  ## Stale-run age gate (US-36.1)

  The `:verification` queue was an unconsumed queue from Epic 26 until US-36.1 registered it,
  so a backlog of `pending` runs and `available` jobs had accumulated. `perform/1` therefore
  retires a NOT-YET-STARTED run older than `verification_max_run_age_seconds` (default 24h)
  as `"skipped"` (`reason: "stale_run_skipped"`) and cancels the job with no read.
  `"skipped"`, not `"error"`: a deliberate non-execution carries no fault and no verification
  signal (see `Loopctl.Verification.complete_run/3`).

  No run status here ever touches `stories.verified_status`: the chain-of-custody verify action
  is entirely separate (`LoopctlWeb.StoryVerificationController`).
  """

  use Oban.Worker, queue: :verification, max_attempts: 3

  require Logger

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Verification
  alias Loopctl.Verification.CiTarget
  alias Loopctl.Verification.Credential

  @ci_adapter Application.compile_env(:loopctl, :ci_adapter, Loopctl.Verification.GitHubActions)

  # 24h: a day-old commit's CI status carries no verification signal worth waiting for, and
  # the accumulated pre-registration backlog is exactly this class of run.
  @default_max_run_age_seconds 24 * 60 * 60

  @terminal ~w(pass fail error skipped)

  @min_snooze_seconds 60
  @max_snooze_seconds 15 * 60
  @max_forge_delay_seconds 60 * 60

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
      case written(Verification.start_run(run)) do
        {:ok, started} -> execute(started, tenant_id)
        {:wait, :database_busy} -> {:snooze, snooze_seconds(run)}
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
        "(age #{age_seconds}s > #{max_run_age_seconds()}s) — no CI read"
    )

    run
    |> Verification.complete_run("skipped", %{
      "reason" => "stale_run_skipped",
      "age_seconds" => age_seconds
    })
    |> settled(run, {:cancel, :stale_run})
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

      # The run has its disposition, so a retry would only find it terminal (#931 finding g).
      # A disposition loopctl could not write is a snooze, and the next poll runs again.
      case no_verdict(run, "internal_error") do
        :ok -> {:cancel, :internal_error}
        snooze -> snooze
      end
  end

  # -- resolving what to read -------------------------------------------------------------

  # Returns the run (with what this poll recorded on it) and the outcome.
  defp verify(run, tenant_id) do
    with {:ok, sha} <- commit_sha(run),
         :ok <- tenant_named(tenant_id),
         {:ok, target} <- CiTarget.gather(tenant_id, run.story_id),
         {:ok, credential} <- credential(tenant_id, target.repo),
         {:ok, run, full} <- full_sha(run, target.repo, sha, credential) do
      judge(run, Map.merge(target, %{sha: full, credential: credential}))
    else
      outcome -> {run, outcome}
    end
  end

  defp judge(run, request) do
    case change_checked(run, request) do
      {:ok, run} -> {run, @ci_adapter.verdict(request)}
      outcome -> {run, outcome}
    end
  end

  # The change check, once per run (moduledoc, 6). Only a pass is stamped: a refusal ends the
  # run, and a wait asks again next poll.
  defp change_checked(%{change_checked_at: %DateTime{}} = run, _request), do: {:ok, run}

  defp change_checked(run, request) do
    with :ok <- @ci_adapter.check_change(request), do: stamp_change_checked(run)
  end

  defp stamp_change_checked(run),
    do: written(Verification.record_poll(run, %{change_checked_at: DateTime.utc_now()}))

  defp commit_sha(%{commit_sha: sha}) when is_binary(sha) and sha != "", do: {:ok, sha}
  defp commit_sha(_run), do: {:unconfigured, "no_commit_sha"}

  # Before any read of the story (finding 9, round 2): a tenant the operator named for no
  # repository at all records `credential_unavailable` without the intake-source, stage-row or
  # dispatch-ledger reads `CiTarget` makes. The pair is still checked once the repository is
  # known (`credential/2`).
  defp tenant_named(tenant_id) do
    if Credential.any_for_tenant?(tenant_id),
      do: :ok,
      else: {:unconfigured, "credential_unavailable"}
  end

  # Asked for the (tenant, repository) pair: an allowlisted tenant gets no credential for a
  # repository it enrolled that the operator did not name with it.
  defp credential(tenant_id, repo) do
    case Credential.for_read(tenant_id, repo) do
      {:ok, %Credential{} = credential} -> {:ok, credential}
      {:error, :credential_unavailable} -> {:unconfigured, "credential_unavailable"}
    end
  end

  # AC-26.4.6.7: a full id is used as it is; an abbreviated one is resolved ONCE and the
  # answer persisted, so no later poll of this run reads the commit again. It leaves the fault
  # streak alone: it is not a CI answer, and it happens once per run.
  defp full_sha(%{resolved_commit_sha: full} = run, _repo, _sha, _credential)
       when is_binary(full),
       do: {:ok, run, full}

  defp full_sha(run, repo, sha, credential) do
    if Loopctl.GitSha.valid?(sha) do
      {:ok, run, sha}
    else
      case @ci_adapter.resolve_commit(repo, sha, credential) do
        {:ok, full} -> record_resolved(run, full)
        outcome -> outcome
      end
    end
  end

  defp record_resolved(run, full) do
    with {:ok, run} <- written(Verification.record_poll(run, %{resolved_commit_sha: full})),
         do: {:ok, run, full}
  end

  # -- settling one outcome ----------------------------------------------------------------

  defp settle({run, {:pass, evidence}}) do
    run
    |> Verification.complete_run("pass", %{"source" => "ci", "evidence_url" => evidence.url})
    |> settled(run, :ok)
  end

  defp settle({run, {:fail, evidence}}) do
    run
    |> Verification.complete_run("fail", %{
      "source" => "ci",
      "evidence_url" => evidence.url,
      "failed_check" => evidence.check,
      "conclusion" => evidence.conclusion
    })
    |> settled(run, :ok)
  end

  defp settle({run, {:wait, :ci_pending}}) do
    if expired?(run.inserted_at) do
      no_verdict(run, "ci_wait_exhausted")
    else
      # The poll ended in a CI answer: a fault streak, if any, is over.
      run |> reset_faults() |> settled(run, {:snooze, snooze_seconds(run)})
    end
  end

  # Every poll that ends in a transient fault counts, whichever read faulted.
  defp settle({run, {:wait, {:transient, retry_after}}}) do
    faults = (run.ci_forge_faults || 0) + 1

    if faults > MergePrecondition.max_consecutive_unevaluated() or expired?(run.inserted_at) do
      no_verdict(run, "forge_unavailable")
    else
      run
      |> Verification.record_poll(%{ci_forge_faults: faults})
      |> settled(
        run,
        {:snooze, faults |> fault_backoff_seconds() |> max(forge_delay(retry_after))}
      )
    end
  end

  # loopctl's own database, not the forge: waited on the CI cadence, never counted as a fault.
  defp settle({run, {:wait, :database_busy}}) do
    if expired?(run.inserted_at),
      do: no_verdict(run, "database_busy"),
      else: {:snooze, snooze_seconds(run)}
  end

  # A refusal, a missing configuration and a permanent forge answer all end the run with no
  # verdict and its code.
  defp settle({run, {kind, code}}) when kind in [:refused, :unconfigured, :no_verdict],
    do: no_verdict(run, code)

  defp reset_faults(%{ci_forge_faults: 0} = run), do: {:ok, run}
  defp reset_faults(run), do: Verification.record_poll(run, %{ci_forge_faults: 0})

  defp no_verdict(run, code) do
    run
    |> Verification.complete_run("error", %{"source" => "ci", "ci_unavailable_reason" => code})
    |> settled(run, :ok)
  end

  # Every write this worker makes to its run is bounded (`Loopctl.Verification`, "Bounded
  # writes"). One loopctl's database could not make is `{:wait, :database_busy}`: loopctl's
  # own database, not the forge and not a verdict, so it leaves the run, and its fault streak,
  # exactly as they were, and the next poll redoes the work. A refused changeset is a fault in
  # loopctl, and raises.
  defp written({:ok, run}), do: {:ok, run}
  defp written({:error, :busy}), do: {:wait, :database_busy}

  # A write made while settling: `done` once it is made; a snooze on the database cadence when
  # it could not be. Never `settle/1` again, so a write that cannot be made never recurses.
  defp settled(write, run, done) do
    case written(write) do
      {:ok, _written} -> done
      {:wait, :database_busy} -> {:snooze, snooze_seconds(run)}
    end
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
