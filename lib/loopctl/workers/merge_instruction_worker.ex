defmodule Loopctl.Workers.MergeInstructionWorker do
  @moduledoc """
  Runs the merge gate for ONE pr-route story at ONE head and, on `:allow`, instructs the runner
  holding its claim to merge (Epic 48, US-48.17): `Loopctl.Delivery.MergeExecution.instruct/2`.

  Enqueued by `Loopctl.Workers.MergeSweepWorker`. **Unique per `(story_id, head_sha)`** across
  every incomplete state, so however many sweeps see the same story at the same head, one job
  runs the gate and pushes; a new head is a new job. The job re-reads the instruction record
  on the stage row before it pushes, so a completed job's successor (the next sweep's resend
  after the answer window) pushes only when the record says one is due.

  Args carry ids only: `tenant_id`, `story_id`, `head_sha`. Every value the instruction names
  is read from control's own rows when the job runs.

  `{:snooze, seconds}` when the forge could not be read (its own `Retry-After`) or the tenant
  is halted; `{:cancel, reason}` for an answer no retry changes (a tenant not human-anchored,
  a repository on the change protocol); a refused write is an error and Oban retries it.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:story_id, :head_sha],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Loopctl.Delivery.MergeExecution

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case MergeExecution.instruct(args) do
      {:ok, _outcome} -> :ok
      other -> other
    end
  end
end
