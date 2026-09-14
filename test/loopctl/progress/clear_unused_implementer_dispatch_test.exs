defmodule Loopctl.Progress.ClearUnusedImplementerDispatchTest do
  @moduledoc """
  Issue #803 — `Progress.clear_unused_implementer_dispatch/3`, the narrow undo the placement
  compensation path needs and nothing else may use.

  `release_claim_changes/1` deliberately keeps `implementer_dispatch_id` on an unclaimed or
  reclaimed story: that is the provenance the L4 gates compare. The one case where it is
  VACUOUS is a placement that claimed a story, failed before any session started, released it,
  and is about to revoke the dispatch it recorded — at which point leaving the id behind
  POISONS the story, because `lineage_status/2` reads a revoked dispatch as an empty lineage
  and fails CLOSED.

  Both conditions in its WHERE are tested here rather than described, because the placement's
  own happy path cannot reach either: at the moment it calls this, the story is always
  `pending` and always names this dispatch, so a mutation that DROPS a condition stays green
  against that test. (`bin/mutate.sh` said exactly that — dropping the `agent_status` guard
  came back exit 1 against `placement_test.exs`.)
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})
    %{tenant: tenant, story: story}
  end

  test "clears the id when the story is pending and names THAT dispatch", ctx do
    %{tenant: tenant, story: story} = ctx
    dispatch_id = dispatch(tenant)
    record(story, dispatch_id, :pending)

    assert {:ok, :cleared} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch_id)

    assert is_nil(reload(story).implementer_dispatch_id)
  end

  test "leaves a story somebody re-claimed between the release and this call alone", ctx do
    %{tenant: tenant, story: story} = ctx
    dispatch_id = dispatch(tenant)

    # The race the `agent_status == :pending` condition exists for: the compensation released
    # the claim, another agent claimed the story, and by the time this runs the id it is about
    # to clear belongs to work that is now UNDER WAY.
    record(story, dispatch_id, :assigned)

    assert {:ok, :unchanged} =
             Progress.clear_unused_implementer_dispatch(tenant.id, story.id, dispatch_id)

    assert reload(story).implementer_dispatch_id == dispatch_id
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
end
