defmodule Loopctl.Workers.ThreadMergeWorkerTest do
  @moduledoc """
  US-45.5 (AC-45.5.1): the merge job is unique per story while one is waiting, RUNNING or
  backing off, so two executors never race one story. The executor's behaviour is tested
  end to end in `Loopctl.Delivery.MergePreconditionIntegrationTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Workers.ThreadMergeWorker

  test "one job per story, across every live state, for as long as it lives" do
    tenant_id = Ecto.UUID.generate()
    story_id = Ecto.UUID.generate()

    unique =
      %{"tenant_id" => tenant_id, "story_id" => story_id}
      |> ThreadMergeWorker.new()
      |> Ecto.Changeset.get_field(:unique)

    assert unique.period == :infinity
    assert Enum.sort(unique.keys) == [:story_id, :tenant_id]

    for state <- [:available, :scheduled, :executing, :retryable] do
      assert state in unique.states, "#{state} must dedupe"
    end
  end
end
