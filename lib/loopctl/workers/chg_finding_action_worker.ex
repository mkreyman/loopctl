defmodule Loopctl.Workers.ChgFindingActionWorker do
  @moduledoc """
  US-51.1 — drains the chg feedback loop's outbox (`Loopctl.Changes.Findings`): opens, and
  later closes, reopens and escalates, the GitHub issue a finding owes. Runs every two minutes
  via Oban Cron.

  The bounds are `Loopctl.Workers.ChangeRevertIssueWorker`'s: `@batch` candidates per run,
  oldest first, fleet-wide on `AdminRepo`; a wall-clock budget checked before each candidate;
  the first rate-limited result halts the batch; one candidate that raises costs only that
  candidate, and a run in which every candidate errored is an error for the job. The pass is
  `Loopctl.ForgeOutbox.drain/4`.

  Overlapping runs cannot double-act: `Loopctl.Changes.FindingFiler` takes a compare-and-set
  on the row before its first forge call, and `unique` below only saves work.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Changes.FindingFiler
  alias Loopctl.Changes.Findings
  alias Loopctl.ForgeOutbox

  @batch 20
  @run_budget_ms 70_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Findings.due(@batch)
    |> sweep()
    |> ForgeOutbox.drain_result("ChgFindingActionWorker")
  end

  @doc """
  One pass over `candidates`, stopping at `deadline` or the first rate-limited result. Public
  with the deadline as an argument so the budget is falsifiable without spending it.
  """
  @spec sweep([map()], integer()) :: [{map(), FindingFiler.outcome() | :errored}]
  def sweep(candidates, deadline \\ System.monotonic_time(:millisecond) + @run_budget_ms) do
    ForgeOutbox.drain(candidates, deadline, &FindingFiler.perform/1,
      label: "ChgFindingActionWorker",
      id_name: "action_id"
    )
  end
end
