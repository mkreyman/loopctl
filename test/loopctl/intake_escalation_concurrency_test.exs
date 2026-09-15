defmodule Loopctl.IntakeEscalationConcurrencyTest do
  @moduledoc """
  `Loopctl.Intake.escalate_record/3` is a read-modify-write of a LIST, and this is the one
  property no sandboxed test can express: the sandbox gives every process the SAME connection,
  so two "concurrent" escalations there are serial by construction and the defect is invisible.

  `async: false` and COMMITTED rows, on two real connections, because the row lock is the thing
  under test and a lock only exists between transactions that are actually separate.

  ## What this does NOT prove

  That the lock is EXCLUSIVE. The holder below takes `FOR UPDATE` directly, so a `FOR SHARE`
  in `escalate_record/3` still blocks it and this test stays green (verified: that mutation
  returns exit 1). Discriminating the two needs both contenders to go through
  `escalate_record/3` with one of them pausing mid-transaction, and there is no seam for that.
  Removing the lock entirely is what this catches, and that is the defect it was written for.
  """
  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Intake
  alias Loopctl.Intake.Record

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    sweep_committed_runner_tenants()
    %{tenant: fixture(:committed_tenant, %{})}
  end

  test "a concurrent escalation keeps BOTH reasons, rather than the later one winning", %{
    tenant: tenant
  } do
    {_source, record} = fixture(:committed_intake, %{tenant_id: tenant.id})
    test_pid = self()

    # The HOLDER stands in for whichever escalation gets there first — in production, the
    # delivery path recording an injection signal while the triage worker records a triage
    # failure. It takes the row lock, tells the test, and waits to commit until told.
    holder =
      spawn_link(fn ->
        Sandbox.unboxed_run(AdminRepo, fn ->
          AdminRepo.transaction(fn ->
            locked =
              AdminRepo.one!(from r in Record, where: r.id == ^record.id, lock: "FOR UPDATE")

            send(test_pid, :locked)
            receive do: (:commit -> :ok)

            {:ok, _} =
              AdminRepo.update(
                Record.apply_changeset(locked, %{
                  status: :escalated,
                  escalation_reasons: ["untrusted_text:injection_markers"],
                  escalated_at: DateTime.utc_now()
                })
              )
          end)
        end)
      end)

    assert_receive :locked, 5_000

    contender =
      Task.async(fn ->
        Sandbox.unboxed_run(AdminRepo, fn ->
          Intake.escalate_record(tenant.id, record.id, "triage_trigger:target_epic_missing")
        end)
      end)

    # It must still be waiting: with the lock in place the contender cannot even READ yet.
    # A liveness precondition, not the discriminator — without the lock it would be blocked
    # at the UPDATE instead, and would look identical from here.
    assert Task.yield(contender, 300) == nil

    send(holder, :commit)

    assert {:ok, {:ok, updated}} = Task.yield(contender, 10_000)

    # THE DISCRIMINATOR. Without `FOR UPDATE` the contender reads `escalation_reasons` BEFORE
    # the holder commits, so its subtraction runs against an empty list and its update writes
    # a list assembled from that pre-state: the holder's reason is gone from the row, while
    # the hash-chained audit log still carries the holder's entry saying it was recorded. Two
    # escalations, one surviving reason, nothing anywhere reporting a loss — and the signal
    # most likely to be dropped is the injection marker, because it is written by the delivery
    # path the moment the text arrives, while the triage failure lands a minute later.
    assert updated.escalation_reasons == [
             "triage_trigger:target_epic_missing",
             "untrusted_text:injection_markers"
           ]

    assert reloaded(record.id).escalation_reasons == updated.escalation_reasons
    assert updated.status == :escalated
  end

  defp reloaded(id) do
    Sandbox.unboxed_run(AdminRepo, fn -> AdminRepo.get!(Record, id) end)
  end
end
