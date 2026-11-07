defmodule Loopctl.Workers.VerifyVerdictWorker do
  @moduledoc """
  Applies one `verify@1` verdict (US-48.18) — `Loopctl.Agents.VerifyVerdict.apply/1`.

  Enqueued by `VerifyVerdict.enqueue/1` after the dispatch ledger's transaction commits, and
  by the minute sweep (`VerifyVerdict.enqueue_unapplied/1`) for a verdict whose insert was
  lost. Its args are ids only; the verdict is read back off the ledger row. UNIQUE per
  `(story_id, dispatch_id)` across every state and for ever: one verifier dispatch has one
  verdict, so a replayed `agent_result` and the sweep enqueue nothing twice. The job is idempotent anyway — each custody step is skipped
  when already done — so a retry after a crash resumes rather than repeats.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:story_id, :dispatch_id], states: :all]

  alias Loopctl.Agents.VerifyVerdict

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case VerifyVerdict.apply(args) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
      {:cancel, reason} -> {:cancel, reason}
      {:snooze, seconds} -> {:snooze, seconds}
    end
  end
end
