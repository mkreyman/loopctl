defmodule Loopctl.Workers.TriageTriggerWorkerLockTest do
  @moduledoc """
  `Loopctl.Workers.TriageTriggerWorker` when the stage open cannot get its lock: a transient
  failure the next run clears, so the record stays `pending_triage` and is never escalated.

  `async: false`, and COMMITTED, because the subject is a `stories` row held `FOR UPDATE` by
  a SECOND Postgres session while the run's `Stages.open/3` waits on it for a share lock. A
  lock cannot be held against your own connection, and another session cannot see a
  sandboxed row, so the story is committed under a `fixture(:committed_tenant)` and swept.
  Every path without the second session is in the async `Loopctl.Workers.TriageTriggerWorkerTest`.

  The run drains this test's tenant only (`drain/1`'s `:tenant_id`), so a committed record
  some other module or an earlier run left `pending_triage` is not its candidate. The
  tenants this module commits are recorded as they are made and swept, those and no others,
  when the module ends: a sweep per test would wait on the test's own still-open sandbox
  transaction.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake.Record
  alias Loopctl.Test.RowLock
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.Workers.TriageTriggerWorker

  setup :verify_on_exit!

  setup_all do
    %{ledger: track_committed_tenants()}
  end

  setup %{ledger: ledger} do
    tenant = fixture(:committed_tenant, %{})
    track_committed_tenant(ledger, tenant.id)
    %{tenant: tenant}
  end

  test "a transient failure leaves the record pending_triage and unescalated", %{
    tenant: tenant
  } do
    {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 43})

    story = create_story(tenant.id, source.target_epic_id, record.id, "43.1")

    # `Stages.open/3` takes the story `FOR SHARE` before it touches the stage row, so a
    # session holding that row `FOR UPDATE` parks the open until the 2s `lock_timeout`
    # `Stages` sets locally fires. A LOCK, not a sleep: nothing here depends on timing.
    blocker = RowLock.hold!("stories", story.id)

    try do
      assert :ok = run(tenant)
    after
      RowLock.release(blocker)
    end

    # The record must NOT be escalated: the next run clears this by itself, and an
    # escalation is never cleared — so filing one here would put a question with no answer
    # in front of a person and take the record out of the read that would have fixed it.
    assert %Record{status: :pending_triage, escalation_reasons: []} = reload(record)
    assert unboxed(fn -> Stages.get(tenant.id, story.id) end) == nil
  end

  defp run(tenant), do: unboxed(fn -> TriageTriggerWorker.drain(tenant_id: tenant.id) end)

  # UNBOXED: the story must be COMMITTED for the second session to see and lock it, and the
  # run commits what it writes, as it does in production.
  defp unboxed(fun) do
    Sandbox.unboxed_run(Loopctl.Repo, fun)
  end

  defp reload(%Record{} = record) do
    unboxed(fn -> AdminRepo.get!(Record, record.id) end)
  end

  defp create_story(tenant_id, epic_id, record_id, number) do
    {:ok, story} =
      unboxed(fn ->
        Stories.create_story(
          tenant_id,
          %{epic_id: epic_id, number: number, title: "Triage pending: already created"},
          intake_record_id: record_id
        )
      end)

    story
  end
end
