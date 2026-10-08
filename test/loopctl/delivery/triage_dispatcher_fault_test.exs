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

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageDispatcher
  alias Loopctl.Repo
  alias Loopctl.Test.ProductionTopology

  @budgets %{wall_clock_seconds: 900, max_turns: 30}

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
      broken = detected_story(ctx)
      half_take(ctx, broken)
      fine = detected_story(ctx)
      half_take(ctx, fine)

      # A fault no refusal names, on the broken row only: committed DDL, which is why this
      # module is `async: false` (see the moduledoc).
      name = "test_stranded_fault_" <> String.replace(broken.id, "-", "")

      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'some_other_fault: injected by test';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE UPDATE ON story_stages FOR EACH ROW
      WHEN (NEW.story_id = '#{broken.id}') EXECUTE FUNCTION #{name}()
      """)

      on_exit(fn ->
        :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON story_stages")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)

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
      broken = detected_story(ctx)
      half_take(ctx, broken)
      fine = detected_story(ctx)
      half_take(ctx, fine)

      name = "test_stranded_hol_" <> String.replace(broken.id, "-", "")

      AdminRepo.query!("""
      CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'some_other_fault: injected by test';
      END
      $$
      """)

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE UPDATE ON story_stages FOR EACH ROW
      WHEN (NEW.story_id = '#{broken.id}') EXECUTE FUNCTION #{name}()
      """)

      on_exit(fn ->
        :ok = ProductionTopology.checkout_unboxed!([AdminRepo])

        AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON story_stages")
        AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      # A pass limit of ONE, and the failing row is the older: bounded by the pass's limit, the
      # sweep would take only it, every pass, and never reach `fine`.
      ExUnit.CaptureLog.with_log(fn ->
        TriageDispatcher.run_with(1, @budgets)
      end)

      assert Stages.get(ctx.tenant.id, fine.id).stage == :escalated
    end
  end

  # A story as INTAKE leaves it: created from a record, its stage row open at `detected`, its
  # project bound to a repository.
  defp detected_story(ctx, opts \\ []) do
    story = fixture(:ledger_story, %{tenant_id: ctx.tenant.id})

    if Keyword.get(opts, :intake_record, true),
      do: attach_record(ctx, story, Keyword.get(opts, :bind_repo, true), opts)

    {:ok, _row} = Stages.open(ctx.tenant.id, story.id, actor_label: "test")
    story
  end

  # The record AND its source, on the story's own project when the story is meant to be
  # addressable. `intake_sources_active_repo_uidx` allows ONE active source per repository per
  # tenant, so the fixture's source has to BE the story's rather than a second one beside it.
  #
  # `bind_repo: false` leaves the source on the fixture's own project instead, which is the
  # real shape of a story whose project nobody bound: it has a record and no repository.
  defp attach_record(ctx, story, bind_repo?, opts) do
    repo = "mkreyman/repo-#{System.unique_integer([:positive])}"

    attrs =
      if bind_repo?,
        do: %{
          tenant_id: ctx.tenant.id,
          project_id: story.project_id,
          issue_number: 412,
          repo_full_name: repo
        },
        else: %{tenant_id: ctx.tenant.id, issue_number: 412, repo_full_name: repo}

    attrs =
      case Keyword.get(opts, :body) do
        nil -> attrs
        body -> Map.put(attrs, :untrusted_body, body)
      end

    {_source, record} = fixture(:intake_pair, attrs)

    {1, _} =
      AdminRepo.update_all(
        from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id),
        set: [intake_record_id: record.id]
      )

    record
  end

  # The FIRST half of the too-large route alone: `triaged`, nothing bound, no verdict.
  defp half_take(ctx, story) do
    row = Stages.get(ctx.tenant.id, story.id)

    {:ok, _row} =
      Stages.advance(ctx.tenant.id, story.id, {:detected, :triaged, :forward},
        claim_epoch: row.claim_epoch,
        actor_label: "worker:triage_dispatcher",
        actor_role: :agent,
        actor_lineage: []
      )
  end
end
