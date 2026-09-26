defmodule Loopctl.Delivery.DispatchPayloadStoryBranchTest do
  @moduledoc """
  `Loopctl.Delivery.DispatchPayload.story_branch/2` (US-45.4): the branch a story was
  DISPATCHED on, read from the dispatch ledger rather than derived again. The merge gate reads
  a thread-mode story's head from it, so a derivation that disagreed with the dispatch would
  judge a branch nobody pushed to.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Delivery.DispatchPayload
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord

  setup do
    story = fixture(:stage_story, %{})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
    %{story: story, runner: runner}
  end

  defp record(ctx, kind, branch, at) do
    {:ok, row} =
      Repo.with_tenant(ctx.story.tenant_id, fn ->
        Repo.insert!(%DispatchRecord{
          tenant_id: ctx.story.tenant_id,
          runner_id: ctx.runner.id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: ctx.story.id,
          claim_epoch: 0,
          kind: kind,
          branch: branch,
          status: "accepted",
          wall_clock_seconds: 3_600,
          released_at: DateTime.utc_now(),
          inserted_at: at,
          updated_at: at
        })
      end)

    row
  end

  test "the newest implement dispatch's recorded branch is the story's branch", ctx do
    record(ctx, "implement", "agent/old-name", ~U[2026-09-26 10:00:00.000000Z])
    record(ctx, "implement", "agent/new-name", ~U[2026-09-26 11:00:00.000000Z])

    assert DispatchPayload.story_branch(ctx.story.tenant_id, ctx.story) == "agent/new-name"
  end

  test "a triage dispatch's branch is never the story's branch", ctx do
    record(ctx, "implement", "agent/implement", ~U[2026-09-26 10:00:00.000000Z])
    record(ctx, "triage", "agent/triage", ~U[2026-09-26 11:00:00.000000Z])

    assert DispatchPayload.story_branch(ctx.story.tenant_id, ctx.story) == "agent/implement"
  end

  test "with nothing recorded it is branch_for/2 with no declared prefixes", ctx do
    {:ok, derived} = DispatchPayload.branch_for(ctx.story, [])

    assert DispatchPayload.story_branch(ctx.story.tenant_id, ctx.story) == derived
  end

  test "another tenant's dispatch is never read (tenant isolation)", ctx do
    record(ctx, "implement", "agent/mine", ~U[2026-09-26 10:00:00.000000Z])
    other = fixture(:stage_story, %{})
    {:ok, derived} = DispatchPayload.branch_for(ctx.story, [])

    assert DispatchPayload.story_branch(other.tenant_id, ctx.story) == derived
  end
end
