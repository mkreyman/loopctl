defmodule Loopctl.Workers.ThreadMergeSweepWorker do
  @moduledoc """
  US-45.5 — the backstop for `Loopctl.Workers.ThreadMergeWorker`. Every five minutes it finds
  thread stories at `ci` with a recorded merge-gate allow and enqueues their merge job.

  ## Why it exists

  The gate enqueues the merge when it records an allow, and a run's last attempt escalates
  whatever it left unresolved. Neither survives a job that never finished: a node killed
  mid-run (a brutal kill runs no `rescue` and no `catch`), a redeploy that dropped a job, an
  enqueue that failed after the allow committed. Such a story sits at `ci`, authorised to
  merge, with nothing that will ever merge it. This sweep re-drives it.

  **When it is unnecessary it costs one bounded read and nothing else.** A candidate whose
  job is waiting, running or backing off is deduplicated into that job (the worker is unique
  per story in those states), and the executor re-reads everything itself, so a candidate
  that no longer applies merges nothing. A story leaves the candidate set by leaving `ci` or
  losing its allow.

  The read is fleet-wide on AdminRepo (BYPASSRLS, so its explicit predicates are the only
  scoping, and each candidate carries its own `tenant_id` into the job), bounded to
  `@batch` rows, oldest first, as `Loopctl.Workers.ReviewCeilingWorker` reads. A THREAD story
  is one with a recorded checkpoint; a pull-request story has none and is never a candidate.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 240, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Threads.Checkpoint
  alias Loopctl.Workers.ThreadMergeWorker

  @batch 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    candidates_query()
    |> AdminRepo.all()
    |> Enum.each(fn {tenant_id, story_id} -> ThreadMergeWorker.enqueue(tenant_id, story_id) end)
  end

  @doc false
  # The candidate read, public so a test can check its scoping without running the sweep.
  @spec candidates_query() :: Ecto.Query.t()
  def candidates_query do
    from s in StoryStage,
      as: :stage,
      where: s.stage == :ci and not is_nil(s.merge_gate_allowed_sha),
      where:
        exists(
          from c in Checkpoint,
            where:
              c.tenant_id == parent_as(:stage).tenant_id and
                c.story_id == parent_as(:stage).story_id
        ),
      order_by: [asc: s.updated_at],
      limit: @batch,
      select: {s.tenant_id, s.story_id}
  end
end
