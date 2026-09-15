defmodule Loopctl.Workers.StoryCompletionWorker do
  @moduledoc """
  Finishes a story the loop has verified: `verified -> done`, once a minute (issue #803 §3).

  The cron caller of `Loopctl.Delivery.Completion`, which owns the selection and the
  settlement rule. A cron rather than an endpoint for the same reason
  `Loopctl.Workers.PostDeployVerificationWorker` is one, and more so: by `verified` the
  session ended two stages ago (`deployed` is in `StageMachine.session_ends_at/0`) and the
  story is waiting on an OUTBOX, so there is no principal left who would call anything.

  ## Why this is not folded into the post-deploy sweep

  That worker's candidates are stories at `deployed`, and deciding one costs several GitHub
  calls — it asks the forge whether the deploy held. This one reads two local tables and makes
  no outward call at all. Folding them would put a fast local decision behind a forge round
  trip and a shared run budget, and would give that worker a name that no longer describes
  what it does.

  ## NOT behind `:dispatch_driver_enabled`

  Deliberately, and this is the one place in the loop where that is the right call. The driver
  flag gates DISPATCHING — starting sessions on somebody's machines unattended, which is the
  thing an operator is agreeing to. This worker starts nothing and spends nothing; it records
  that work already finished. A story that reached `verified` got there through a dispatch the
  operator had already allowed, and gating its last transition on a flag would mean a fleet
  that turns the driver off strands every story currently in flight at the final stage —
  reintroducing the absorbing state this closes, on a switch.

  ## Bounded per run

  `@batch` candidates, oldest first, fair across tenants. A remainder is the next pass's first
  candidates because the read is oldest-first, so nothing starves.
  """

  # `unique:` IS NOT OPTIONAL AT THIS CADENCE, and three siblings carry it for a reason found
  # in review (#826 round 3, finding 2): scheduled every minute with `max_attempts: 3`, a
  # systemic failure leaves a RETRYABLE job that does not block the next cron insert, so each
  # tick adds a fresh job beside the backed-off one and the queue accumulates three failures
  # plus a discard per minute indefinitely. The `states:` list is what makes the retryable one
  # count. It also stops a slow pass overlapping the next tick, which would double this
  # sweep's load on the three-connection AdminRepo pool in exactly the situation where it is
  # already struggling.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  alias Loopctl.Delivery.Completion

  require Logger

  @batch 50

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def perform(%Oban.Job{}) do
    @batch |> Completion.candidates() |> sweep() |> run_result()
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The job's result for a pass whose candidates produced `outcomes`.

  A pass where EVERY candidate errored is a systemic failure and must not report a clean run —
  the same rule the triage and driver sweeps apply, and for the same reason: a worker that
  reports `:ok` while completing nothing is indistinguishable from an empty queue, which is
  how the absorbing stage this worker exists to close went unnoticed for so long.

  An EMPTY pass is `:ok`. So is a pass whose candidates were refused `:stale_stage`: that is
  two nodes sweeping the same batch and exactly one committing, which is the design working.
  """
  @spec run_result([atom()]) :: :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def run_result([]), do: :ok

  def run_result(outcomes) do
    errored = Enum.count(outcomes, &(&1 == :errored))

    if errored == length(outcomes),
      do: {:error, {:all_candidates_errored, errored}},
      else: :ok
  end

  defp sweep(candidates), do: Enum.map(candidates, &attempt/1)

  # ONE STORY MAY NOT KILL THE PASS — the read is oldest-first, so a story that raises would
  # sit at the head of every later batch too.
  defp attempt(candidate) do
    case Completion.complete(candidate.tenant_id, candidate.story_id,
           claim_epoch: candidate.claim_epoch
         ) do
      {:ok, _row} ->
        :completed

      # THE ROW MOVED UNDER THE SWEEP, and none of these needs a person. `:stale_stage` is
      # another node completing it or something else advancing it; `:stale_claim_epoch` is the
      # story's epoch moving between the candidate read and the write — a human resolution, a
      # release — and `:not_found` is the row going away.
      #
      # Logged at INFO, like `PostDeployVerificationWorker` logs the same set, and counted
      # apart from `:errored`. At `error` they would be indistinguishable from the systemic
      # failure `run_result/1` exists to surface — and worse, a single legacy row whose
      # `story_stages.claim_epoch` disagrees with its story's would be refused on every pass,
      # so once it was the only candidate left the job would fail EVERY MINUTE for ever on a
      # condition that is not a fault.
      {:error, reason} when reason in [:stale_stage, :stale_claim_epoch, :not_found] ->
        Logger.info(
          "StoryCompletionWorker: skipped, the row moved: story_id=#{candidate.story_id} " <>
            "reason=#{inspect(reason)}",
          tenant_id: candidate.tenant_id,
          story_id: candidate.story_id
        )

        :raced

      # The closure went unsettled between the candidate read and the re-check — in practice
      # an operator's `requeue_abandoned/1`. The story is a candidate again once the drainer
      # closes it.
      {:waiting, :closure_unsettled} ->
        :waiting

      {:error, reason} ->
        Logger.error(
          "StoryCompletionWorker: could not complete a verified story: " <>
            "story_id=#{candidate.story_id} reason=#{inspect(reason)}",
          tenant_id: candidate.tenant_id,
          story_id: candidate.story_id
        )

        :errored
    end
  rescue
    error -> errored(candidate, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(candidate, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(candidate, detail) do
    Logger.error(
      "StoryCompletionWorker: candidate failed, continuing with the rest of the pass: " <>
        "story_id=#{candidate.story_id} detail=#{detail}",
      tenant_id: candidate.tenant_id,
      story_id: candidate.story_id
    )

    :errored
  end
end
