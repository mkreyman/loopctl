defmodule Loopctl.Delivery.TriageTriggerLockTest do
  @moduledoc """
  `Loopctl.Delivery.TriageTrigger.promote/1` against a story row ANOTHER database session holds
  `FOR UPDATE` (#803 §2/§4): the stage open must answer `{:error, {:stage_not_opened, :busy}}`
  rather than report a story the loop cannot see.

  `async: false`, and COMMITTED, because a lock held by a second connection is the subject:
  the holder is a raw Postgrex session, which cannot see a sandbox transaction's rows, and a
  lock cannot be held against the connection that waits on it. So the tenant is
  `fixture(:committed_tenant)`, every write after `setup` commits on production's two
  connections (`Loopctl.Test.ProductionTopology`), and `sweep_committed_runner_tenants/0`
  removes it all at the module boundaries. The rest of `promote/1` is
  `Loopctl.Delivery.TriageTriggerTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures
  import Mox, only: [verify_on_exit!: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageTrigger
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.Test.RowLock
  alias Loopctl.WorkBreakdown.Stories

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    # This module is on ExUnit.Case, so it gets none of DataCase's stubs: installed here, so a
    # Mox-resolved dependency the promote reaches answers with the default instead of raising.
    # Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first; from the
    # checkout on, every write of this process commits.
    tenant = fixture(:committed_tenant, %{})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])
    %{tenant: tenant}
  end

  test "a stage that could not be opened is an error, not a story the loop cannot see", %{
    tenant: tenant
  } do
    {source, record} = fixture(:intake_pair, %{tenant_id: tenant.id, epic_number: 43})

    # The story exists and is LINKED to the record but has no stage row — the state a
    # promote whose open failed leaves behind. Created here rather than by a first promote
    # so that the open under test is the FIRST one, and its failure therefore leaves the
    # story genuinely invisible rather than merely re-failing on a row that already exists.
    assert {:ok, story} =
             Stories.create_story(
               tenant.id,
               %{
                 epic_id: source.target_epic_id,
                 number: "43.1",
                 title: "Triage pending: already created"
               },
               intake_record_id: record.id
             )

    # `Stages.open/3` takes the story `FOR SHARE` before it touches the stage row, so a
    # session holding that row `FOR UPDATE` parks the open until the 2s `lock_timeout`
    # `Stages` sets locally fires — the `{:error, :busy}` its moduledoc calls ordinary and
    # retryable. A LOCK, not a sleep: nothing here depends on timing.
    blocker = RowLock.hold!("stories", story.id)

    try do
      # The first version of `opened/2` matched `{_row, _}`, which `{:error, :busy}`
      # satisfies as well as `{:ok, row}`: promote answered `{:ok, story}`, the caller
      # marked the record promoted, and the story sat for ever with nothing to advance it
      # and nothing to retry it.
      assert {:error, {:stage_not_opened, :busy}} =
               TriageTrigger.promote(record)
    after
      RowLock.release(blocker)
    end

    # The half that makes the error true: `Loopctl.Delivery.Placement` selects on the stage
    # row and nothing else, so with no row the loop cannot see this story at all.
    assert Stages.get(tenant.id, story.id) == nil
  end
end
