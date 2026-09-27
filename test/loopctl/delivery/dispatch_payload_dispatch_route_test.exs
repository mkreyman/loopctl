defmodule Loopctl.Delivery.DispatchPayloadDispatchRouteTest do
  @moduledoc """
  `Loopctl.Delivery.DispatchPayload.dispatch_route/2` and `thread_branch/3` (US-45.4): the
  merge mode, base branch and branch a story's CURRENT claim was placed under, read from the
  implement ledger row of that claim its runner accepted, and the branch a thread is judged on. The merge gate judges a story on this route,
  so a later source change, a triage row, or a dispatch that never ran must not change it.
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
          mode: Keyword.get(fields, :mode),
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

  defp thread_branch(ctx, stage_branch \\ nil) do
    {:ok, route} = route(ctx)
    DispatchPayload.thread_branch(route, ctx.story, stage_branch)
  end

  @t1 ~U[2026-09-26 10:00:00.000000Z]
  @t2 ~U[2026-09-26 11:00:00.000000Z]
  @t3 ~U[2026-09-26 12:00:00.000000Z]

  test "the mode is the one the claim's dispatch recorded at placement", ctx do
    record(ctx, @t1, mode: "thread", branch: "agent/b")

    assert {:ok, %{mode: :thread, branch: "agent/b"}} = route(ctx)
  end

  test "the base branch is the one the claim's dispatch was sent with; none is nil", ctx do
    assert {:ok, %{base_branch: nil}} = route(ctx)

    record(ctx, @t1, mode: "thread", base_branch: "trunk")
    assert {:ok, %{base_branch: "trunk"}} = route(ctx)
  end

  test "a row that recorded no mode is pr; NO row is nil, for the caller's source fallback",
       ctx do
    assert {:ok, %{mode: nil, branch: nil, base_branch: nil}} = route(ctx)

    record(ctx, @t1, branch: "agent/b")
    assert {:ok, %{mode: :pr}} = route(ctx)
  end

  test "thread branch order: the current claim's dispatch, then the stage's, then derived",
       ctx do
    {:ok, derived} = DispatchPayload.branch_for(ctx.story, [])
    assert {:ok, ^derived} = thread_branch(ctx)
    assert {:ok, "loop/earlier-claim"} = thread_branch(ctx, "loop/earlier-claim")

    # Round 3 finding 1: the stage row still names an EARLIER claim's branch after a re-claim;
    # the current claim's dispatched branch wins over it.
    record(ctx, @t1, branch: "agent/dispatched")
    assert {:ok, "agent/dispatched"} = thread_branch(ctx)
    assert {:ok, "agent/dispatched"} = thread_branch(ctx, "loop/earlier-claim")
  end

  test "the newest ACCEPTED row, of the CURRENT claim, of an implement kind", ctx do
    record(ctx, @t1, mode: "thread", branch: "agent/ran")
    record(ctx, @t2, mode: "pr", branch: "agent/refused", status: "refused")
    record(ctx, @t2, mode: "pr", branch: "agent/sent", status: "sent")
    record(ctx, @t2, mode: "pr", branch: "agent/triage", kind: "triage")

    record(ctx, @t3,
      mode: "pr",
      branch: "agent/other-claim",
      claim_epoch: ctx.story.claim_epoch + 1
    )

    assert {:ok, %{mode: :thread, branch: "agent/ran"}} = route(ctx)

    # A superseded row names a claim that has moved on, never the current one's route.
    record(ctx, @t3, mode: "pr", branch: "agent/superseded", status: "superseded")
    assert {:ok, %{mode: :thread, branch: "agent/ran"}} = route(ctx)

    record(ctx, @t3, mode: "pr", branch: "agent/newer")
    assert {:ok, %{mode: :pr, branch: "agent/newer"}} = route(ctx)
  end

  test "another tenant's dispatch is never read (tenant isolation)", ctx do
    record(ctx, @t1, mode: "thread", branch: "agent/mine")
    other = fixture(:stage_story, %{})

    assert {:ok, %{mode: nil, branch: nil}} =
             DispatchPayload.dispatch_route(other.tenant_id, ctx.story)
  end
end
