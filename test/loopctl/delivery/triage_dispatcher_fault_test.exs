defmodule Loopctl.Delivery.TriageDispatcherFaultTest do
  @moduledoc """
  `Loopctl.Delivery.TriageDispatcher.run_with/2` when finishing ONE stranded row raises
  (#803 §4): the rest of the pass still runs, and a failing row does not hold every slot.

  `async: false`, and COMMITTED, because the fault is injected with DDL: a trigger on
  `story_stages` that raises for the broken story alone. DDL on a shared table holds its lock
  until the transaction ends, so inside an async test's sandbox transaction it would stall
  every other test writing `story_stages`. So the tenant is `fixture(:committed_tenant)`, every
  write after `setup` commits on production's two connections
  (`Loopctl.Test.ProductionTopology`), each trigger is dropped on exit, and
  `sweep_committed_runner_tenants/0` removes the rows at the module boundaries. The rest of
  the dispatcher is `Loopctl.Delivery.TriageDispatcherTest`, which is `async: true`.
  """

  use ExUnit.Case, async: false

  import Loopctl.Fixtures
  import Mox, only: [verify_on_exit!: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageDispatcher
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology
  alias Loopctl.Test.TriageDispatch

  @budgets %{wall_clock_seconds: 900, max_turns: 30}

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    # SWEPT BEFORE EVERY TEST, not only at the module boundary: `stranded/1` is fleet-wide, so
    # a stranded row the previous test committed would be one of this pass's outcomes.
    sweep_committed_runner_tenants()

    # `fixture(:committed_tenant)` runs its own unboxed checkout, so it goes first; from the
    # checkout on, every write of this process commits.
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    :ok = ProductionTopology.checkout_unboxed!([Repo, AdminRepo])
    %{tenant: tenant}
  end

  describe "run_with/2 over stranded rows" do
    test "a stranded row whose escalation RAISES does not stop the rest of the pass", ctx do
      broken = fixture(:detected_story, %{tenant_id: ctx.tenant.id})
      TriageDispatch.half_take(ctx.tenant.id, broken)
      fine = fixture(:detected_story, %{tenant_id: ctx.tenant.id})
      TriageDispatch.half_take(ctx.tenant.id, fine)

      # A fault no refusal names, on the broken row only.
      fail_stage_updates!(broken.id)

      outcomes =
        ExUnit.CaptureLog.with_log(fn ->
          TriageDispatcher.run_with(20, @budgets)
        end)
        |> elem(0)

      # Tagged `{:stranded, _}`, so a pass of failing stranded rows is not judged all-errored and
      # retried whole.
      assert Enum.sort(outcomes) == [stranded: :errored, stranded: :escalated]
      assert Stages.get(ctx.tenant.id, fine.id).stage == :escalated
      assert Stages.get(ctx.tenant.id, broken.id).stage == :triaged
    end

    test "failing stranded rows do not hold every slot: a later one is still finished", ctx do
      broken = fixture(:detected_story, %{tenant_id: ctx.tenant.id})
      TriageDispatch.half_take(ctx.tenant.id, broken)
      fine = fixture(:detected_story, %{tenant_id: ctx.tenant.id})
      TriageDispatch.half_take(ctx.tenant.id, fine)

      fail_stage_updates!(broken.id)

      # A pass limit of ONE, and the failing row is the older: bounded by the pass's limit, the
      # sweep would take only it, every pass, and never reach `fine`.
      ExUnit.CaptureLog.with_log(fn ->
        TriageDispatcher.run_with(1, @budgets)
      end)

      assert Stages.get(ctx.tenant.id, fine.id).stage == :escalated
    end
  end

  # Every UPDATE of `story_id`'s stage row raises a fault no refusal names. Committed DDL,
  # which is why this module is `async: false` (see the moduledoc).
  #
  # The drop is registered BEFORE the create, so no path out of this function leaves the
  # objects with nothing registered to drop them (`IF EXISTS` makes it a no-op when the create
  # never committed).
  # `SET LOCAL`, never a bare `SET`: `CREATE TRIGGER` takes an ACCESS EXCLUSIVE lock, so this
  # fails fast instead of hanging the run, and the setting reverts with the transaction rather
  # than riding a pooled connection into the next test.
  defp fail_stage_updates!(story_id) do
    name = "test_stage_fault_" <> String.replace(story_id, "-", "")
    on_exit(fn -> drop_stage_fault!(name) end)

    {:ok, _} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!("SET LOCAL lock_timeout = '5s'")

        AdminRepo.query!("""
        CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          RAISE EXCEPTION 'some_other_fault: injected by test';
        END
        $$
        """)

        AdminRepo.query!("""
        CREATE TRIGGER #{name} BEFORE UPDATE ON story_stages FOR EACH ROW
        WHEN (NEW.story_id = '#{story_id}') EXECUTE FUNCTION #{name}()
        """)
      end)

    :ok
  end

  # Unguarded and outside a transaction, deliberately. A `lock_timeout` here would abort with
  # the trigger still installed, which IS the leak the drop exists to prevent; unguarded it
  # waits and then succeeds. Unwrapped, the trigger (the object that does the damage) goes
  # first, and a failed function drop leaves an orphan nothing fires.
  defp drop_stage_fault!(name) do
    :ok = ProductionTopology.checkout_unboxed!([AdminRepo])
    AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON story_stages")
    AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
    :ok
  end
end
