defmodule Loopctl.Progress.ClearUnusedImplementerDispatchTest do
  @moduledoc """
  Issue #803 — `Progress.clear_unused_implementer_dispatch/3`, the narrow undo the placement
  compensation path needs and nothing else may use.

  `release_claim_changes/1` deliberately keeps `implementer_dispatch_id` on an unclaimed or
  reclaimed story: that is the provenance the L4 gates compare. The one case where it is
  VACUOUS is a placement that claimed a story, failed before any session started, and released
  it — the recorded dispatch did nothing, and the next claimant is then judged against it:
  refused `caller_lineage_required` if unlineaged, `self_report_blocked` if its lineage shares
  a chain with the stale one.

  **Revocation has nothing to do with it**, contrary to what this file used to say. A revoked
  dispatch still resolves its `lineage_path` — `Dispatches.get_dispatch/2` has no `revoked_at`
  filter and `revoke/2` leaves the path intact — so `:unresolvable` comes only from a missing
  or foreign row, and a revoked recorded dispatch behaves exactly like a live one.

  Its WHERE is tested here rather than described, because the placement's own happy path cannot
  reach the cases that decide it: at the moment it calls this, the story always names this
  dispatch, so a mutation that DROPS a condition stays green against `placement_test.exs`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})
    %{tenant: tenant, story: story}
  end

  test "clears the id when the story names THAT dispatch", ctx do
    %{tenant: tenant, story: story} = ctx
    dispatch_id = dispatch(tenant)
    record(story, dispatch_id, :pending)

    assert {:ok, :cleared} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch_id)

    assert is_nil(reload(story).implementer_dispatch_id)
  end

  test "clears it even on a story a LEGACY BEARER key has already re-claimed", ctx do
    %{tenant: tenant, story: story} = ctx
    dispatch_id = dispatch(tenant)

    # There was an `agent_status == :pending` condition here, to leave a re-claimed story
    # alone. This is the case that shows it was wrong. A re-claim THROUGH A DISPATCH overwrites
    # `implementer_dispatch_id`, so the id predicate already declines those; a BEARER re-claim
    # writes no dispatch id, so the story is `:assigned` and still names the dead placement's
    # dispatch — and there the stale id is exactly as poisonous for the new claimant, who is
    # the unlineaged caller `caller_lineage_required` refuses.
    record(story, dispatch_id, :assigned)

    assert {:ok, :cleared} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch_id)

    assert is_nil(reload(story).implementer_dispatch_id)
  end

  test "a re-claim through a DISPATCH is declined, because it overwrote the id", ctx do
    %{tenant: tenant, story: story} = ctx
    dead_placement = dispatch(tenant)
    new_implementer = dispatch(tenant)
    record(story, new_implementer, :assigned)

    assert {:ok, :unchanged} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dead_placement)

    assert reload(story).implementer_dispatch_id == new_implementer
  end

  test "records the clear on the audit log", ctx do
    %{tenant: tenant, story: story} = ctx
    dispatch_id = dispatch(tenant)
    record(story, dispatch_id, :pending)

    {:ok, :cleared} = Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch_id)

    # `update_all` bypasses changesets, so without this nothing records that the story STOPPED
    # naming the dispatch — while the hash chain still carries `dispatch_created` and
    # `story_stage_claimed` naming it.
    assert %{action: "implementer_dispatch_cleared"} = entry = latest_entry(tenant, story)
    assert entry.old_state["implementer_dispatch_id"] == dispatch_id
    assert entry.new_state["implementer_dispatch_id"] == nil
  end

  test "never erases a DIFFERENT implementer's provenance", ctx do
    %{tenant: tenant, story: story} = ctx
    real_implementer = dispatch(tenant)
    record(story, real_implementer, :pending)

    assert {:ok, :unchanged} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch(tenant))

    assert reload(story).implementer_dispatch_id == real_implementer
  end

  test "another tenant cannot clear this tenant's story", ctx do
    %{tenant: tenant, story: story} = ctx
    other = fixture(:tenant)
    dispatch_id = dispatch(tenant)
    record(story, dispatch_id, :pending)

    assert {:ok, :unchanged} =
             Progress.clear_unused_implementer_dispatch(other.id, story.id, dispatch_id)

    assert reload(story).implementer_dispatch_id == dispatch_id
    assert tenant.id != other.id
  end

  # A REAL dispatch row: `stories_implementer_dispatch_id_fkey` refuses a bare uuid, and an FK
  # check bypasses RLS, so the row has to exist.
  defp dispatch(tenant) do
    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent}, actor_lineage: [])

    dispatch.id
  end

  # Written directly: `implementer_dispatch_id` is set by the claim, and the states under test
  # are ones no ordinary transition produces.
  defp record(story, dispatch_id, agent_status) do
    story
    |> Ecto.Changeset.change(implementer_dispatch_id: dispatch_id, agent_status: agent_status)
    |> AdminRepo.update!()
  end

  defp reload(story), do: AdminRepo.get!(Story, story.id)

  defp latest_entry(tenant, story) do
    import Ecto.Query, only: [from: 2]

    AdminRepo.one!(
      from e in AuditLog,
        where: e.tenant_id == ^tenant.id and e.entity_id == ^story.id,
        where: e.action == "implementer_dispatch_cleared"
    )
  end
end
