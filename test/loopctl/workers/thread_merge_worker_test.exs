defmodule Loopctl.Workers.ThreadMergeWorkerTest do
  @moduledoc """
  US-45.5 (AC-45.5.1): the merge job is unique per story while one is waiting, running or
  backing off, so one run per story at a time. The executor's behaviour, and the rerun that
  replaces an enqueue lost to that uniqueness, are tested end to end in
  `Loopctl.Delivery.MergePreconditionIntegrationTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Workers.ThreadMergeWorker

  test "one job per story, running included, for as long as it lives" do
    unique =
      %{"tenant_id" => Ecto.UUID.generate(), "story_id" => Ecto.UUID.generate()}
      |> ThreadMergeWorker.new()
      |> Ecto.Changeset.get_field(:unique)

    assert unique.period == :infinity
    assert Enum.sort(unique.keys) == [:story_id, :tenant_id]

    assert Enum.sort(unique.states) ==
             Enum.sort([:available, :scheduled, :executing, :retryable])
  end

  # Why a run whose allow changed SNOOZES rather than enqueueing: an enqueue while the story's
  # job executes is deduplicated into that very job.
  test "an enqueue while the story's job executes is absorbed by it" do
    tenant_id = Ecto.UUID.generate()
    story_id = Ecto.UUID.generate()

    Oban.Testing.with_testing_mode(:manual, fn ->
      :ok = ThreadMergeWorker.enqueue(tenant_id, story_id)

      Repo.update_all(from(j in Oban.Job, where: j.args["story_id"] == ^story_id),
        set: [state: "executing"]
      )

      :ok = ThreadMergeWorker.enqueue(tenant_id, story_id)
      assert jobs(story_id) == ["executing"]
    end)
  end

  defp jobs(story_id) do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == "Loopctl.Workers.ThreadMergeWorker",
        where: j.args["story_id"] == ^story_id,
        select: j.state
    )
  end
end
