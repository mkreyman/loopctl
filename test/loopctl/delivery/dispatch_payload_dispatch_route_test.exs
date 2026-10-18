defmodule Loopctl.Delivery.DispatchPayloadDispatchRouteTest do
  @moduledoc """
  `Loopctl.Delivery.DispatchPayload.dispatch_route/2`: the base branch and branch a story's
  CURRENT claim was placed under, read from the implement ledger row of that claim its runner
  accepted. Story verification judges a story on this route, so a later source change, a
  triage row, or a dispatch that never ran must not change it.
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

  defp record(ctx, at, fields) do
    status = Keyword.get(fields, :status, "accepted")

    {:ok, row} =
      Repo.with_tenant(ctx.story.tenant_id, fn ->
        Repo.insert!(%DispatchRecord{
          tenant_id: ctx.story.tenant_id,
          runner_id: ctx.runner.id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: ctx.story.id,
          claim_epoch: Keyword.get(fields, :claim_epoch, ctx.story.claim_epoch),
          kind: Keyword.get(fields, :kind, "implement"),
          branch: Keyword.get(fields, :branch),
          base_branch: Keyword.get(fields, :base_branch),
          status: status,
          # `runner_dispatches_reason_iff_refused`: a refused row carries its reason.
          reason: if(status == "refused", do: "unsupported_kind"),
          wall_clock_seconds: 3_600,
          released_at: DateTime.utc_now(),
          inserted_at: at,
          updated_at: at
        })
      end)

    row
  end

  defp route(ctx), do: DispatchPayload.dispatch_route(ctx.story.tenant_id, ctx.story)

  @t1 ~U[2026-09-26 10:00:00.000000Z]
  @t2 ~U[2026-09-26 11:00:00.000000Z]
  @t3 ~U[2026-09-26 12:00:00.000000Z]

  test "the base branch is the one the claim's dispatch was sent with; none is nil", ctx do
    assert {:ok, %{base_branch: nil}} = route(ctx)

    record(ctx, @t1, base_branch: "trunk")
    assert {:ok, %{base_branch: "trunk"}} = route(ctx)
  end

  test "dispatch_route/4 reads the claim of the epoch it is given, not the current one ",
       ctx do
    earlier = ctx.story.claim_epoch
    record(ctx, @t1, base_branch: "release-1", claim_epoch: earlier)
    record(ctx, @t2, base_branch: "main", claim_epoch: earlier + 1)

    story = %{ctx.story | claim_epoch: earlier + 1}

    assert {:ok, %{base_branch: "main"}} = DispatchPayload.dispatch_route(story.tenant_id, story)

    assert {:ok, %{base_branch: "release-1"}} =
             DispatchPayload.dispatch_route(story.tenant_id, story, earlier)

    assert {:ok, %{base_branch: nil}} =
             DispatchPayload.dispatch_route(story.tenant_id, story, earlier + 7)
  end

  test "NO row is all nil, for the caller's source fallback", ctx do
    assert {:ok, %{branch: nil, base_branch: nil}} = route(ctx)
  end

  test "the newest ACCEPTED row, of the CURRENT claim, of an implement kind", ctx do
    record(ctx, @t1, branch: "agent/ran")
    record(ctx, @t2, branch: "agent/refused", status: "refused")
    record(ctx, @t2, branch: "agent/sent", status: "sent")
    record(ctx, @t2, branch: "agent/triage", kind: "triage")

    record(ctx, @t3,
      branch: "agent/other-claim",
      claim_epoch: ctx.story.claim_epoch + 1
    )

    assert {:ok, %{branch: "agent/ran"}} = route(ctx)

    # A superseded row names a claim that has moved on, never the current one's route.
    record(ctx, @t3, branch: "agent/superseded", status: "superseded")
    assert {:ok, %{branch: "agent/ran"}} = route(ctx)

    record(ctx, @t3, branch: "agent/newer")
    assert {:ok, %{branch: "agent/newer"}} = route(ctx)
  end

  test "another tenant's dispatch is never read (tenant isolation)", ctx do
    record(ctx, @t1, branch: "agent/mine")
    other = fixture(:stage_story, %{})

    assert {:ok, %{branch: nil}} =
             DispatchPayload.dispatch_route(other.tenant_id, ctx.story)
  end
end
