defmodule Loopctl.Workers.IntakeIssueCloseWorker do
  @moduledoc """
  #805 item 1 — drains the issue-closure outbox: tells the person who reported a GitHub issue
  what happened to it. Runs every two minutes via Oban Cron.

  ## Why a drainer and not a call at the verdict

  The verdict is written inside a database transaction (`Loopctl.Delivery.Stages`), and
  closing an issue is four bounded network calls to GitHub. Doing it there would mean either
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
  on `:pending` before its first forge call, so of two runs holding the same candidate exactly
  one proceeds and the other reports `:skipped`. Behind that, one row per story decided by a
  unique index, and a read of the issue's live state that catches even a crash between a
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
    interval minus one candidate's worst case (four bounded calls at 2s connect + 5s receive,
    so ~28s). Checked only afterwards, a run could start a candidate just under the budget and
    finish past the interval, which drops the next tick to the `unique` window and halves the
    cadence.
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
    unique: [period: 120, states: [:available, :scheduled, :executing]]

  require Logger

  alias Loopctl.Delivery.IssueCloser
  alias Loopctl.Intake.IssueClosures

  @batch 20

  # Wall clock for one run, checked BEFORE each candidate.
  #
  # A candidate's worst case is four bounded requests (read, label, comment, close) at 2s
  # connect + 5s receive, so ~28s. 90s + 28s stays inside the 120s cron interval. In the
  # ordinary case a candidate costs four sub-second calls and a full batch finishes in a
  # second or two; this bounds the pathological run, and the remainder is not lost — it is the
  # next run's first candidates, since the read is oldest-first.
  @run_budget_ms 90_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = sweep(IssueClosures.due(@batch))

    tally = Enum.frequencies_by(results, fn {_closure, outcome} -> outcome end)

    if map_size(tally) > 0 do
      Logger.info("IntakeIssueCloseWorker: #{inspect(tally)}")
    end

    :ok
  end

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
    {outcome, retry_after} = IssueCloser.close(closure)
    acc = [{closure, outcome} | acc]

    if is_integer(retry_after), do: {:halt, acc}, else: {:cont, acc}
  end

  defp log_budget_spent(acc) do
    Logger.info(
      "IntakeIssueCloseWorker: wall-clock budget spent after #{length(acc)} " <>
        "candidate(s); the rest are the next run's"
    )

    acc
  end
end
