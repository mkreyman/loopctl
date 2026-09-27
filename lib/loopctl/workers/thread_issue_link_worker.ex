defmodule Loopctl.Workers.ThreadIssueLinkWorker do
  @moduledoc """
  US-45.7 (AC-45.7.4): drains the thread-link outbox, `Loopctl.Threads.IssueLinks` — one
  comment on a story's intake issue carrying the URL of the story's thread page. Runs every two
  minutes via Oban Cron.

  The same drainer shape as `Loopctl.Workers.IntakeIssueCloseWorker`, for the same reasons: the
  intent is written in the checkpoint's transaction so it cannot be lost, and the comment is
  posted here with nothing held, so the network is never inside a transaction. A candidate is
  ONE bounded forge call, the first rate-limited answer stops the run, and one candidate that
  raises costs that candidate rather than the batch. It holds no state; a node that dies
  mid-run leaves rows the next run on any node re-reads.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  alias Loopctl.Threads.IssueLinks

  @batch 20

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results =
      IssueLinks.due(@batch)
      |> Enum.reduce_while([], fn link, acc ->
        {outcome, retry_after} = attempt(link)
        acc = [outcome | acc]
        if is_integer(retry_after), do: {:halt, acc}, else: {:cont, acc}
      end)

    tally = Enum.frequencies(results)
    if map_size(tally) > 0, do: Logger.info("ThreadIssueLinkWorker: #{inspect(tally)}")

    # Every candidate erroring is a bad WORLD (a pool outage), not a bad row: fail the job so
    # Oban retries it and it shows as discarded rather than as a clean run.
    if results != [] and Map.get(tally, :errored, 0) == length(results),
      do: {:error, {:all_candidates_errored, length(results)}},
      else: :ok
  end

  @doc "The thread page's absolute URL for `story_id`, as the issue comment carries it."
  @spec thread_url(Ecto.UUID.t()) :: String.t()
  def thread_url(story_id), do: LoopctlWeb.Endpoint.url() <> "/threads/" <> story_id

  defp attempt(link) do
    IssueLinks.attempt(link, thread_url(link.story_id))
  rescue
    error -> errored(link, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(link, Exception.format(kind, value, __STACKTRACE__))
  end

  defp errored(link, detail) do
    Logger.error(
      "ThreadIssueLinkWorker: candidate failed, continuing: tenant_id=#{link.tenant_id} " <>
        "story_id=#{link.story_id} link_id=#{link.id} detail=#{detail}"
    )

    {:errored, nil}
  end
end
