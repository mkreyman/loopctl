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
    candidate's worst case (two bounded GitHub calls, a marker read and a create, at 2s
    connect + 5s receive: ~14s);
  - the first rate-limited result halts the batch;
  - one candidate that raises or exits costs that candidate, logged at ERROR, and a run in
    which EVERY candidate errored is an error for the job, so a systemic failure is visible.

  Overlapping runs cannot double-open: `Loopctl.Changes.RevertIssueOpener` takes a
  compare-and-set on the row before its first forge call, and `unique` below only saves work.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Changes.RevertIssueOpener
  alias Loopctl.Changes.RevertIssues

  @batch 20
  @run_budget_ms 100_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = sweep(RevertIssues.due(@batch))
    tally = Enum.frequencies_by(results, fn {_row, outcome} -> outcome end)

    if map_size(tally) > 0, do: Logger.info("ChangeRevertIssueWorker: #{inspect(tally)}")

    errored = Map.get(tally, :errored, 0)

    if results != [] and errored == length(results),
      do: {:error, {:all_candidates_errored, errored}},
      else: :ok
  end

  @doc """
  One pass over `candidates`, stopping at `deadline` (a `System.monotonic_time(:millisecond)`
  value) or at the first rate-limited result. Public with the deadline as an argument so the
  budget is falsifiable without spending it.
  """
  @spec sweep([map()], integer()) :: [{map(), RevertIssueOpener.outcome() | :errored}]
  def sweep(candidates, deadline \\ System.monotonic_time(:millisecond) + @run_budget_ms) do
    candidates
    |> Enum.reduce_while([], fn row, acc ->
      if System.monotonic_time(:millisecond) >= deadline,
        do: {:halt, acc},
        else: after_candidate(row, acc)
    end)
    |> Enum.reverse()
  end

  # A rate-limited forge is a reason to stop asking, not to ask the rest of the batch.
  defp after_candidate(row, acc) do
    {outcome, retry_after} = attempt(row)
    acc = [{row, outcome} | acc]
    if is_integer(retry_after), do: {:halt, acc}, else: {:cont, acc}
  end

  defp attempt(row) do
    RevertIssueOpener.open(row)
  rescue
    error -> errored(row, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(row, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(row, detail) do
    Logger.error(
      "ChangeRevertIssueWorker: candidate failed, continuing with the rest of the batch: " <>
        "tenant_id=#{row.tenant_id} story_id=#{row.story_id} row_id=#{row.id} detail=#{detail}",
      tenant_id: row.tenant_id,
      story_id: row.story_id
    )

    {:errored, nil}
  end
end
