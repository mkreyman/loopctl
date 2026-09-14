defmodule Loopctl.Workers.IntakeIssueCloseWorker do
  @moduledoc """
  #805 item 1 — drains the issue-closure outbox: tells the person who reported a GitHub issue
  what happened to it. Runs every two minutes via Oban Cron.

  ## Why a drainer and not a call at the verdict

  The verdict is written inside a database transaction (`Loopctl.Delivery.Stages`), and
  closing an issue is five bounded network calls to GitHub. Doing it there would mean either
  holding a pooled connection and the story's row lock across those calls, or performing the
  outward act after the commit and losing it outright if the node died in between.

  So the transaction writes INTENT — one `intake_issue_closures` row, atomically with the
  verdict — and this worker performs the act with nothing held. That split is what gives both
  properties at once: the intent cannot be lost, and the network is never inside a
  transaction.

  It also means the two verdicts do not each need their own enqueue. The shipped one is
  written by `Loopctl.Delivery.PostDeployVerification` today; the not-actionable one by
  whatever writes `:triage_reject` when triage lands. Both go through
  `Loopctl.Delivery.Stages`, so both produce a row, and this worker never learns there are
  two writers.

  ## Idempotent, and safe to run twice

  Overlapping runs cannot double-close. `Loopctl.Delivery.IssueCloser` takes a compare-and-set
  on `:pending` AND on the row being DUE before its first forge call, pushing `next_attempt_at`
  forward — so of two runs holding the same candidate exactly one proceeds and the other
  reports `:skipped`. That CAS is the mechanism; Oban's `unique` option below reduces wasted
  work and is NOT what makes this safe, which matters because `unique` does not survive a
  manual enqueue or a retry landing beside a slow run. Behind it, one row per story decided by
  a unique index, and a read of the issue's live state that catches even a crash between a
  successful close and the record of it.

  A story with NO intake link never produced a row, so it is not a candidate and closes
  nothing. That is the ordinary case and not an error.

  ## The candidate read, and what bounds a run

  `:pending` closures whose backoff has elapsed, fleet-wide, oldest first, on `AdminRepo`
  (BYPASSRLS, so the explicit predicates are the only scoping) — the same shape as
  `Loopctl.Workers.PostDeployVerificationWorker`. A decided closure drops out of the next
  run's candidates by itself, and a deferred one comes back when its backoff expires.

  Three bounds, for the same reasons the verifier has three:

  - `@batch` candidates, so one run cannot spend an hourly rate limit in a minute.
  - `@run_budget_ms` of wall clock, checked BEFORE each candidate and sized as the cron
    interval minus one candidate's worst case (FIVE bounded calls at 2s connect + 5s receive,
    so ~35s — the fifth is the pre-close state re-read added by #826 round 2). Checked only
    afterwards, a run could start a candidate just under the budget and finish past the
    interval, which drops the next tick to the `unique` window and halves the cadence.
  - Oban `unique` over the cron interval, so an overrunning run does not get a second copy of
    itself doubling the traffic to a forge that is already struggling.

  **A rate limit stops the run.** The first result carrying a `retry_after` halts the batch:
  the remaining candidates would ask a forge that has already said it is out of quota.

  ## How it resumes

  It holds no state. A node that dies mid-run leaves rows whose markers say how far each
  attempt got, and the next run on any node re-reads them.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    # `:retryable` is in the states deliberately (#826 round 3, finding 2). Before this PR's
    # round-2 change `perform/1` always returned `:ok`, so no job of this worker could ever BE
    # retryable and omitting the state cost nothing. Now a systemic failure returns an error —
    # and without `:retryable` here the backed-off job does not block the next cron insert, so
    # a two-minute cadence accumulates a retryable job PLUS a fresh one every tick, each up to
    # `max_attempts`. That is exactly the doubling this option is documented below as
    # preventing, arriving in the one situation where the forge is already struggling.
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Delivery.IssueCloser
  alias Loopctl.Intake.IssueClosures

  @batch 20

  # Wall clock for one run, checked BEFORE each candidate.
  #
  # A candidate's worst case is FIVE bounded requests — read, label, comment, re-read, close —
  # at 2s connect + 5s receive, so ~35s. 80s + 35s stays inside the 120s cron interval.
  #
  # It was 90s while the worst case was four calls; #826 round 2 added the pre-close state
  # re-read, and leaving the budget alone would have let a run start a candidate at 89s and
  # finish at ~124s, past the interval — which drops the next tick to the `unique` window and
  # silently halves the cadence. A budget sized against a stale call count is not a budget.
  #
  # In the ordinary case a candidate costs five sub-second calls and a full batch finishes in
  # a second or two; this bounds the pathological run, and the remainder is not lost — it is
  # the next run's first candidates, since the read is oldest-first.
  @run_budget_ms 80_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = sweep(IssueClosures.due(@batch))

    tally = Enum.frequencies_by(results, fn {_closure, outcome} -> outcome end)

    if map_size(tally) > 0 do
      Logger.info("IntakeIssueCloseWorker: #{inspect(tally)}")
    end

    run_result(results, Map.get(tally, :errored, 0))
  end

  # A SYSTEMIC failure must not report as a successful job (#826 round 2, finding 2).
  #
  # The per-candidate rescue below is right for ONE bad row and wrong for a bad WORLD: on a
  # connection-pool outage every candidate raises, the rescue swallows each, `perform/1`
  # returned `:ok`, and Oban recorded a clean run. `max_attempts` never fired, no job went to
  # `discarded`, and nothing anywhere alerted — the failure was visible only as twenty log
  # lines nobody was watching.
  #
  # So: every candidate erroring is an ERROR for the job, which Oban retries and eventually
  # discards where it can be seen. A run with some errors and some progress stays `:ok` —
  # that is the one-bad-row case the rescue exists for, and the row's own attempt counter
  # bounds it.
  defp run_result([], _errored), do: :ok

  defp run_result(results, errored) when errored == length(results) do
    {:error, {:all_candidates_errored, errored}}
  end

  defp run_result(_results, _errored), do: :ok

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc false
  @spec run_budget_ms() :: pos_integer()
  def run_budget_ms, do: @run_budget_ms

  defp sweep(candidates),
    do: sweep(candidates, System.monotonic_time(:millisecond) + @run_budget_ms)

  @doc """
  One pass over `candidates`, stopping at `deadline` (a `System.monotonic_time(:millisecond)`
  value) or at the first rate-limited result.

  Public with the deadline as an argument ONLY so the budget's behaviour is falsifiable: it is
  a compile-time constant measured in tens of seconds, and a test that had to spend it in real
  time could not tell "checked before the candidate" from "checked after". Production calls
  `sweep/1`, which computes the deadline itself.
  """
  @spec sweep([map()], integer()) :: [{map(), IssueCloser.outcome()}]
  def sweep(candidates, deadline) do
    candidates
    |> Enum.reduce_while([], fn closure, acc ->
      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, log_budget_spent(acc)}
      else
        after_candidate(closure, acc)
      end
    end)
    |> Enum.reverse()
  end

  # `reduce_while` rather than `map`: a rate-limited forge is a reason to stop asking, not a
  # reason to ask nineteen more times.
  defp after_candidate(closure, acc) do
    {outcome, retry_after} = attempt(closure)
    acc = [{closure, outcome} | acc]

    if is_integer(retry_after), do: {:halt, acc}, else: {:cont, acc}
  end

  # ONE CANDIDATE MAY NOT KILL THE RUN (#826 review, finding 5).
  #
  # An exception here propagates out of `perform/1`, so every remaining candidate in the batch
  # is skipped and an Oban attempt is burned — and since `due/1` reads oldest-first, a row that
  # raises reliably sits at the head of the next batch too. That is a fleet-wide stall caused
  # by one issue, across every tenant.
  #
  # The specific way in was a length-CHECK violation inside the very write that records "never
  # retry this", and that root cause is fixed at the bound in `Loopctl.Intake.IssueClosures`.
  # This is the containment: whatever else can raise, it costs one candidate.
  #
  # It is SAFE to carry on because `claim_attempt/2` already committed before anything outward
  # ran — the attempt is counted, and the row is scheduled forward — so a raising row waits its
  # backoff like a transient failure and is still bounded by `max_attempts/0` rather than
  # retrying for ever. Nothing is swallowed silently: it is logged at ERROR with the row's
  # identity, and `perform/1` turns a whole batch of them into a failed job.
  #
  # EXITS are caught as well as raises (#826 round 2, finding 2). Rescue alone missed the very
  # class this is written for: a `Finch` pool checkout timeout, a `GenServer.call` timeout and
  # a `DBConnection` ownership failure all EXIT rather than raise, so each still killed the
  # batch while the rescue looked like it covered them. `catch` takes both kinds.
  defp attempt(closure) do
    IssueCloser.close(closure)
  rescue
    error -> errored(closure, Exception.format(:error, error, __STACKTRACE__))
  catch
    # The `:exit` clause is for the MESSAGE only — `Exception.format_exit/1` renders a pool
    # checkout timeout readably where the generic formatter does not. The catch-all below it
    # already handles exits, so removing this clause changes no behaviour and `bin/mutate.sh`
    # correctly returns exit 1 on it; the falsifiable guard is the whole `catch`, which a
    # mutation does turn red.
    :exit, reason -> errored(closure, "exit: " <> Exception.format_exit(reason))
    kind, value -> errored(closure, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(closure, detail) do
    Logger.error(
      "IntakeIssueCloseWorker: candidate failed, continuing with the rest of the batch: " <>
        "tenant_id=#{closure.tenant_id} story_id=#{closure.story_id} " <>
        "closure_id=#{closure.id} detail=#{detail}",
      tenant_id: closure.tenant_id,
      story_id: closure.story_id
    )

    {:errored, nil}
  end

  defp log_budget_spent(acc) do
    Logger.info(
      "IntakeIssueCloseWorker: wall-clock budget spent after #{length(acc)} " <>
        "candidate(s); the rest are the next run's"
    )

    acc
  end
end
