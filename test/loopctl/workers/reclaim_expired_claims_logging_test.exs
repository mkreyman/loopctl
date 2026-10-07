defmodule Loopctl.Workers.ReclaimExpiredClaimsLoggingTest do
  @moduledoc """
  Issue #815: the sweep names every candidate it did not skip, with its tenant, story and
  epoch — the summary line only counts them.

  The worker's `:info` level is raised once in `test/test_helper.exs`, never per test.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReclaimExpiredClaimsWorker

  setup :verify_on_exit!

  test "a reclaimed candidate is logged with its tenant, story, old and new epoch" do
    tenant = fixture(:tenant)
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})
    {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

    {1, _} =
      from(s in Story, where: s.id == ^story.id)
      |> AdminRepo.update_all(
        set: [claimed_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    log =
      capture_log([level: :info], fn ->
        assert :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})
      end)

    assert log =~
             "ReclaimExpiredClaimsWorker: reclaimed: tenant_id=#{tenant.id} story_id=#{story.id} " <>
               "claim_epoch=#{claimed.claim_epoch} new_claim_epoch=#{claimed.claim_epoch + 1}"
  end
end
