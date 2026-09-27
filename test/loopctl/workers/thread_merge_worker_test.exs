defmodule Loopctl.Workers.ThreadMergeWorkerTest do
  @moduledoc """
  US-45.5 (AC-45.5.1): the merge job is unique per story while one is waiting or backing
  off, and NOT while one runs, so an allow recorded during a run is never dropped. The
  executor's behaviour is tested end to end in `Loopctl.Delivery.MergePreconditionIntegrationTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Workers.ThreadMergeWorker

  test "one job per story while waiting, for as long as it waits; a RUNNING job does not absorb one" do
    unique =
      %{"tenant_id" => Ecto.UUID.generate(), "story_id" => Ecto.UUID.generate()}
      |> ThreadMergeWorker.new()
      |> Ecto.Changeset.get_field(:unique)

    assert unique.period == :infinity
    assert Enum.sort(unique.keys) == [:story_id, :tenant_id]
    assert Enum.sort(unique.states) == Enum.sort([:available, :scheduled, :retryable])
  end

  test "finding 7: an enqueue while the story's job is executing produces a second job" do
    tenant_id = Ecto.UUID.generate()
    story_id = Ecto.UUID.generate()

    Oban.Testing.with_testing_mode(:manual, fn ->
      :ok = ThreadMergeWorker.enqueue(tenant_id, story_id)
      # A waiting job absorbs a second enqueue.
      :ok = ThreadMergeWorker.enqueue(tenant_id, story_id)
      assert jobs(story_id) == ["available"]

      Repo.update_all(from(j in Oban.Job, where: j.args["story_id"] == ^story_id),
        set: [state: "executing"]
      )

      :ok = ThreadMergeWorker.enqueue(tenant_id, story_id)
      assert Enum.sort(jobs(story_id)) == ["available", "executing"]
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
