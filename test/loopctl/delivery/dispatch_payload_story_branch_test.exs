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

  defp record(ctx, kind, branch, at, overrides \\ []) do
    {:ok, row} =
      Repo.with_tenant(ctx.story.tenant_id, fn ->
        Repo.insert!(%DispatchRecord{
          tenant_id: ctx.story.tenant_id,
          runner_id: ctx.runner.id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: ctx.story.id,
          claim_epoch: Keyword.get(overrides, :claim_epoch, 0),
          kind: kind,
          branch: branch,
          status: Keyword.get(overrides, :status, "accepted"),
          # `runner_dispatches_reason_iff_refused`: a refused row carries its reason.
          reason: if(Keyword.get(overrides, :status) == "refused", do: "unsupported_kind"),
          wall_clock_seconds: 3_600,
          released_at: DateTime.utc_now(),
          inserted_at: at,
          updated_at: at
        })
      end)

    row
  end

  defp branch(ctx, epoch \\ 0),
    do: DispatchPayload.story_branch(ctx.story.tenant_id, ctx.story, epoch)

  test "the newest implement dispatch of the claim that RAN names the story's branch", ctx do
    record(ctx, "implement", "agent/old-name", ~U[2026-09-26 10:00:00.000000Z])

    record(ctx, "implement", "agent/new-name", ~U[2026-09-26 11:00:00.000000Z],
      status: "superseded"
    )

    assert branch(ctx) == {:ok, "agent/new-name"}
  end

  test "a triage dispatch's branch is never the story's branch", ctx do
    record(ctx, "implement", "agent/implement", ~U[2026-09-26 10:00:00.000000Z])
    record(ctx, "triage", "agent/triage", ~U[2026-09-26 11:00:00.000000Z])

    assert branch(ctx) == {:ok, "agent/implement"}
  end

  test "a later row that never ran, or belongs to another claim, is ignored", ctx do
    record(ctx, "implement", "agent/ran", ~U[2026-09-26 10:00:00.000000Z])
    record(ctx, "implement", "agent/refused", ~U[2026-09-26 11:00:00.000000Z], status: "refused")
    record(ctx, "implement", "agent/sent", ~U[2026-09-26 12:00:00.000000Z], status: "sent")

    record(ctx, "implement", "agent/next-claim", ~U[2026-09-26 13:00:00.000000Z], claim_epoch: 1)

    assert branch(ctx, 0) == {:ok, "agent/ran"}
    assert branch(ctx, 1) == {:ok, "agent/next-claim"}
  end

  test "with nothing recorded it is branch_for/2 with no declared prefixes", ctx do
    assert branch(ctx) == DispatchPayload.branch_for(ctx.story, [])
  end

  test "another tenant's dispatch is never read (tenant isolation)", ctx do
    record(ctx, "implement", "agent/mine", ~U[2026-09-26 10:00:00.000000Z])
    other = fixture(:stage_story, %{})

    assert DispatchPayload.story_branch(other.tenant_id, ctx.story, 0) ==
             DispatchPayload.branch_for(ctx.story, [])
  end
end
