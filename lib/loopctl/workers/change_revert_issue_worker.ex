defmodule Loopctl.Workers.ChangeRevertIssueWorker do
  @moduledoc """
  US-47.4 — drains the revert-issue outbox (`Loopctl.Changes.RevertIssues`): opens the GitHub
  issue a chg revert of a `done` story owes, so the revert is triaged as a new report. Runs
  every two minutes via Oban Cron.

  The change event that recorded the row did so inside its own transaction and made no
  outbound call (PRD §12); this performs the act with nothing held. The shape, and every
  bound, is `Loopctl.Workers.IntakeIssueCloseWorker`'s:

  - `@batch` candidates per run, oldest first, fleet-wide on `AdminRepo`;
  - a wall-clock budget checked BEFORE each candidate, sized as the cron interval less one
    candidate's worst case: on a retry, the credential's login, up to five pages of its
    issues and a create — seven bounded GitHub calls at 2s connect + 5s receive, ~49s — so
    70s + 49s stays inside the 120s interval;
  - the first rate-limited result halts the batch;
  - one candidate that raises or exits costs that candidate, logged at ERROR, and a run in
    which EVERY candidate errored is an error for the job, so a systemic failure is visible.

  The pass itself is `Loopctl.ForgeOutbox.drain/4`, the one both drainers run.

  Overlapping runs cannot double-open: `Loopctl.Changes.RevertIssueOpener` takes a
  compare-and-set on the row before its first forge call, and `unique` below only saves work.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Changes.RevertIssueOpener
  alias Loopctl.Changes.RevertIssues
  alias Loopctl.ForgeOutbox

  @batch 20
  @run_budget_ms 70_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    RevertIssues.due(@batch)
    |> sweep()
    |> ForgeOutbox.drain_result("ChangeRevertIssueWorker")
  end

  @doc """
  One pass over `candidates`, stopping at `deadline` (a `System.monotonic_time(:millisecond)`
  value) or at the first rate-limited result (`Loopctl.ForgeOutbox.drain/4`). Public with the
  deadline as an argument so the budget is falsifiable without spending it.
  """
  @spec sweep([map()], integer()) :: [{map(), RevertIssueOpener.outcome() | :errored}]
  def sweep(candidates, deadline \\ System.monotonic_time(:millisecond) + @run_budget_ms) do
    ForgeOutbox.drain(candidates, deadline, &RevertIssueOpener.open/1,
      label: "ChangeRevertIssueWorker"
    )
  end
end
