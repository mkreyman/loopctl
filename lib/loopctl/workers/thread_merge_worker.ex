defmodule Loopctl.Workers.ThreadMergeWorker do
  @moduledoc """
  US-45.5 — runs `Loopctl.Delivery.MergeExecutor` for one THREAD-mode story, which squashes
  the checkpoint the merge gate allowed onto the base branch as loopctl's GitHub App.

  Enqueued by `Loopctl.Delivery.MergePrecondition` on every thread-mode allow it records,
  replays of the same allow included, so a caller that asks the gate again after a lost
  enqueue enqueues again. The job carries only the story: the executor re-reads the allow,
  the checkpoint and the stage row itself, so a job that outlived the allow it was enqueued
  for merges nothing.

  ## Unique per story, running included (AC-45.5.1)

  `states` includes `:executing` and `:retryable` and `period` is `:infinity`: a second
  enqueue while a run is waiting, running or backing off is the SAME job, so two executors
  never race one story. A second allow arriving then is picked up by that job, since it reads
  the current allow rather than the one it was enqueued for. A completed job does not block
  the next allow — the base-update path ends its run with the story waiting on CI for the
  new head, and the gate's allow on that head enqueues afresh.

  ## Retries are bounded, then escalate

  A transient forge fault returns an error and Oban retries with its backoff; the LAST
  attempt escalates instead (`forge_unavailable`), so an allowed story never sits at `ci`
  after the job is discarded. Every other outcome — merged, escalated, sent back, skipped —
  is `:ok`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 8,
    unique: [
      period: :infinity,
      keys: [:tenant_id, :story_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Loopctl.Delivery.MergeExecutor

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"tenant_id" => tenant_id, "story_id" => story_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case MergeExecutor.run(tenant_id, story_id, attempt >= max_attempts) do
      {:retry, reason} -> {:error, reason}
      _outcome -> :ok
    end
  end

  @doc """
  Enqueues the merge of `story_id`. A failed insert is logged and answered `:ok`: the allow
  is already recorded, and the gate's next evaluation enqueues again.
  """
  @spec enqueue(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def enqueue(tenant_id, story_id) do
    case %{"tenant_id" => tenant_id, "story_id" => story_id} |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_enqueue_failure(tenant_id, story_id, reason)
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      log_enqueue_failure(tenant_id, story_id, error)
  end

  defp log_enqueue_failure(tenant_id, story_id, reason) do
    Logger.warning(
      "thread merge job not enqueued; the next gate evaluation enqueues again: " <>
        "#{inspect(reason)} tenant_id=#{tenant_id} story_id=#{story_id}",
      tenant_id: tenant_id,
      story_id: story_id
    )

    :ok
  end
end
