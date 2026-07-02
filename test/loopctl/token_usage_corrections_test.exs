defmodule Loopctl.TokenUsageCorrectionsTest do
  @moduledoc """
  Tests for US-21.13: Token Usage Report Correction & Deletion.

  Covers:
  - AC-21.13.1: DELETE soft-deletes and excludes from queries
  - AC-21.13.2: POST correction creates correction report with corrects_report_id
  - AC-21.13.3: Negative corrections allowed; sum must be >= 0
  - AC-21.13.4: Budget flags reset when spend drops below threshold
  - AC-21.13.5: Audit log entries for deleted/corrected
  - AC-21.13.6: Change feed entries (via audit log)
  - AC-21.13.7: Cost summaries marked stale
  - AC-21.13.9: Tenant isolation — returns 404 for cross-tenant
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.Report

  setup :verify_on_exit!

  defp setup_context do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    %{tenant: tenant, project: project, epic: epic, agent: agent, story: story}
  end

  defp create_report(tenant_id, story, agent, project, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 2500
        },
        overrides
      )

    {:ok, report} = TokenUsage.create_report(tenant_id, attrs)
    report
  end

  defp find_audit_entries(tenant_id, entity_type, action) do
    AuditLog
    |> where(
      [a],
      a.tenant_id == ^tenant_id and
        a.entity_type == ^entity_type and
        a.action == ^action
    )
    |> AdminRepo.all()
  end

  defp count_threshold_audits(tenant_id, threshold_type) do
    tenant_id
    |> find_audit_entries("token_budget", "threshold_crossed")
    |> Enum.count(&(&1.metadata["threshold_type"] == threshold_type))
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.1: Soft delete
  # ---------------------------------------------------------------------------

  describe "delete_report/3 (AC-21.13.1)" do
    test "soft-deletes a report by setting deleted_at" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      assert {:ok, deleted} = TokenUsage.delete_report(tenant.id, report.id)

      assert deleted.deleted_at != nil
      assert deleted.id == report.id
    end

    test "deleted report is excluded from list_reports_for_story" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      {:ok, before_delete} = TokenUsage.list_reports_for_story(tenant.id, story.id)
      assert before_delete.total == 1

      TokenUsage.delete_report(tenant.id, report.id)

      {:ok, after_delete} = TokenUsage.list_reports_for_story(tenant.id, story.id)
      assert after_delete.total == 0
      assert after_delete.data == []
    end

    test "deleted report is excluded from get_story_totals" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      {:ok, before_totals} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert before_totals.total_cost_millicents == 2500

      TokenUsage.delete_report(tenant.id, report.id)

      {:ok, after_totals} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert after_totals.total_cost_millicents == 0
      assert after_totals.report_count == 0
    end

    test "returns not_found for already deleted report" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)
      assert {:error, :not_found} = TokenUsage.delete_report(tenant.id, report.id)
    end

    test "returns not_found for nonexistent report" do
      %{tenant: tenant} = setup_context()
      assert {:error, :not_found} = TokenUsage.delete_report(tenant.id, Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.2: Correction report
  # ---------------------------------------------------------------------------

  describe "create_correction/4 (AC-21.13.2)" do
    test "creates a correction report with corrects_report_id FK" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      assert {:ok, correction} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -100,
                 output_tokens: -50,
                 cost_millicents: -250
               })

      assert correction.corrects_report_id == original.id
      assert correction.story_id == original.story_id
      assert correction.input_tokens == -100
      assert correction.output_tokens == -50
      assert correction.cost_millicents == -250
    end

    test "both original and correction exist in DB" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      {:ok, correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      db_original = AdminRepo.get!(Report, original.id)
      db_correction = AdminRepo.get!(Report, correction.id)

      assert db_original.deleted_at == nil
      assert db_correction.corrects_report_id == original.id
    end

    test "analytics sums all non-deleted reports including corrections" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # 1000 input + 500 output = 2500 cost
      {:ok, totals_before} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert totals_before.total_cost_millicents == 2500

      # Correction subtracts 250
      {:ok, _} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      # Net = 2500 - 250 = 2250
      {:ok, totals_after} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert totals_after.total_cost_millicents == 2250
      # 2 reports: original + correction
      assert totals_after.report_count == 2
    end

    test "correction inherits model_name and phase from original when not specified" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      original =
        create_report(tenant.id, story, agent, project, %{
          model_name: "claude-opus-4",
          phase: "implementing"
        })

      {:ok, correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      assert correction.model_name == "claude-opus-4"
      assert correction.phase == "implementing"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.3: Negative corrections, sum must be >= 0
  # ---------------------------------------------------------------------------

  describe "create_correction/4 negative value validation (AC-21.13.3)" do
    test "allows negative correction values within bounds" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # original: input=1000, output=500, cost=2500
      # correction: input=-999, output=-499, cost=-2499 (all >= 0 after sum)
      assert {:ok, _correction} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -999,
                 output_tokens: -499,
                 cost_millicents: -2499
               })
    end

    test "returns 422 if correction would make input_tokens total negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # input_tokens = 1000, correction = -1001, net = -1
      assert {:error, :unprocessable_entity, message} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -1001,
                 output_tokens: 0,
                 cost_millicents: 0
               })

      assert message =~ "input_tokens"
    end

    test "returns 422 if correction would make output_tokens total negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # output_tokens = 500, correction = -501, net = -1
      assert {:error, :unprocessable_entity, message} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: 0,
                 output_tokens: -501,
                 cost_millicents: 0
               })

      assert message =~ "output_tokens"
    end

    test "returns 422 if correction would make cost_millicents total negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # cost_millicents = 2500, correction = -2501, net = -1
      assert {:error, :unprocessable_entity, message} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: 0,
                 output_tokens: 0,
                 cost_millicents: -2501
               })

      assert message =~ "cost_millicents"
    end

    test "correction that exactly zeroes out a value is allowed" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      # Exactly cancel the cost
      assert {:ok, _} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -1000,
                 output_tokens: -500,
                 cost_millicents: -2500
               })
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.4: Budget flags reset after deletion/correction
  # ---------------------------------------------------------------------------

  describe "budget flag reset (AC-21.13.4)" do
    test "resets warning_fired when spend drops below warning threshold after deletion" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      # Create a budget at 80% warning threshold
      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 3000,
          alert_threshold_pct: 80
        })

      # 80% of 3000 = 2400. Create a report at 2500 (above threshold)
      report = create_report(tenant.id, story, agent, project, %{cost_millicents: 2500})

      # Manually set warning_fired = true (simulating it was fired)
      budget
      |> Ecto.Changeset.change(%{warning_fired: true})
      |> AdminRepo.update!()

      # Delete the report — spend drops to 0 (below 80% threshold)
      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)

      updated_budget = AdminRepo.get!(Budget, budget.id)
      assert updated_budget.warning_fired == false
    end

    test "resets exceeded_fired when spend drops below 100% after deletion" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 2000,
          alert_threshold_pct: 80
        })

      # Spend = 2500 > 2000 budget
      report = create_report(tenant.id, story, agent, project, %{cost_millicents: 2500})

      budget
      |> Ecto.Changeset.change(%{warning_fired: true, exceeded_fired: true})
      |> AdminRepo.update!()

      # Delete the report — spend drops to 0
      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)

      updated_budget = AdminRepo.get!(Budget, budget.id)
      assert updated_budget.warning_fired == false
      assert updated_budget.exceeded_fired == false
    end

    test "does not reset flags when spend is still above threshold after correction" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 1000,
          alert_threshold_pct: 80
        })

      # Two reports: 2000 total (above 1000 budget)
      create_report(tenant.id, story, agent, project, %{cost_millicents: 1500})
      report2 = create_report(tenant.id, story, agent, project, %{cost_millicents: 500})

      budget
      |> Ecto.Changeset.change(%{warning_fired: true, exceeded_fired: true})
      |> AdminRepo.update!()

      # Correction of -100 on report2 → net = 1500 + 400 = 1900 (still above 1000)
      {:ok, _} =
        TokenUsage.create_correction(tenant.id, report2.id, %{
          input_tokens: 0,
          output_tokens: 0,
          cost_millicents: -100
        })

      updated_budget = AdminRepo.get!(Budget, budget.id)
      # Still above 100% threshold so exceeded_fired stays
      assert updated_budget.exceeded_fired == true
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.5: Audit log entries
  # ---------------------------------------------------------------------------

  describe "audit log (AC-21.13.5)" do
    test "deletion creates audit log entry with action='deleted'" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)

      entries = find_audit_entries(tenant.id, "token_usage_report", "deleted")
      assert length(entries) == 1
      entry = hd(entries)
      assert entry.entity_id == report.id
      assert entry.old_state["cost_millicents"] == 2500
    end

    test "correction creates audit log entry with action='corrected'" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      {:ok, correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      entries = find_audit_entries(tenant.id, "token_usage_report", "corrected")
      assert length(entries) == 1
      entry = hd(entries)
      assert entry.entity_id == correction.id
      assert entry.new_state["corrects_report_id"] == original.id
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.6: Change feed entries (via audit log)
  # ---------------------------------------------------------------------------

  describe "change feed (AC-21.13.6)" do
    test "deletion creates a change feed entry visible via audit log" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)

      # Change feed is implemented via audit log (same as AC-21.8.1 pattern)
      entries = find_audit_entries(tenant.id, "token_usage_report", "deleted")
      assert entries != []
    end

    test "correction creates a change feed entry visible via audit log" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      {:ok, _} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      entries = find_audit_entries(tenant.id, "token_usage_report", "corrected")
      assert entries != []
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.7: Cost summaries marked stale
  # ---------------------------------------------------------------------------

  describe "cost summary stale flag (AC-21.13.7)" do
    test "deletion marks affected cost summaries as stale" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      # Insert a cost summary for the story scope
      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :story,
        scope_id: story.id,
        period_start: ~D[2026-04-01],
        period_end: ~D[2026-04-01],
        total_cost_millicents: 2500,
        report_count: 1,
        stale: false
      })
      |> AdminRepo.insert!()

      {:ok, _} = TokenUsage.delete_report(tenant.id, report.id)

      summaries =
        CostSummary
        |> where([cs], cs.tenant_id == ^tenant.id and cs.scope_id == ^story.id)
        |> AdminRepo.all()

      assert Enum.all?(summaries, & &1.stale)
    end

    test "correction marks affected cost summaries as stale" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :story,
        scope_id: story.id,
        period_start: ~D[2026-04-01],
        period_end: ~D[2026-04-01],
        total_cost_millicents: 2500,
        report_count: 1,
        stale: false
      })
      |> AdminRepo.insert!()

      {:ok, _} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      summaries =
        CostSummary
        |> where([cs], cs.tenant_id == ^tenant.id and cs.scope_id == ^story.id)
        |> AdminRepo.all()

      assert Enum.all?(summaries, & &1.stale)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-21.13.9: Tenant isolation
  # ---------------------------------------------------------------------------

  describe "tenant isolation (AC-21.13.9)" do
    test "delete returns not_found when accessing cross-tenant report" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      other_tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.delete_report(other_tenant.id, report.id)

      # Original report should remain untouched
      assert {:ok, _} = TokenUsage.get_report(tenant.id, report.id)
    end

    test "create_correction returns not_found when accessing cross-tenant report" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               TokenUsage.create_correction(other_tenant.id, original.id, %{
                 input_tokens: -100,
                 output_tokens: -50,
                 cost_millicents: -250
               })
    end

    test "tenant A's deleted report does not affect tenant B's list" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      report_a =
        create_report(ctx_a.tenant.id, ctx_a.story, ctx_a.agent, ctx_a.project)

      create_report(ctx_b.tenant.id, ctx_b.story, ctx_b.agent, ctx_b.project)

      TokenUsage.delete_report(ctx_a.tenant.id, report_a.id)

      {:ok, b_result} = TokenUsage.list_reports_for_story(ctx_b.tenant.id, ctx_b.story.id)
      assert b_result.total == 1
    end
  end

  # ---------------------------------------------------------------------------
  # get_report/2 helper
  # ---------------------------------------------------------------------------

  describe "get_report/2" do
    test "returns report when found and active" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      assert {:ok, fetched} = TokenUsage.get_report(tenant.id, report.id)
      assert fetched.id == report.id
    end

    test "returns not_found for soft-deleted report" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      TokenUsage.delete_report(tenant.id, report.id)

      assert {:error, :not_found} = TokenUsage.get_report(tenant.id, report.id)
    end

    test "returns not_found for cross-tenant" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      report = create_report(tenant.id, story, agent, project)

      other_tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.get_report(other_tenant.id, report.id)
    end
  end

  # ---------------------------------------------------------------------------
  # tokens-02: concurrent correction validation cannot drive totals negative
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # tokens-03 retention gap: correction chains are bounded to depth 1
  # ---------------------------------------------------------------------------

  describe "create_correction/4 forbids correcting a correction (tokens-03)" do
    test "correcting an ORIGINAL report succeeds" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      assert {:ok, _correction} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -100,
                 output_tokens: -50,
                 cost_millicents: -250
               })
    end

    test "correcting a CORRECTION returns 422 (bounds the chain to depth 1)" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      {:ok, correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      # A correction-of-a-correction would create an unbounded lineage
      # (A <- B <- C ...) that defers hard-delete of the whole chain past
      # retention forever. It must be rejected.
      assert {:error, :unprocessable_entity, message} =
               TokenUsage.create_correction(tenant.id, correction.id, %{
                 input_tokens: -10,
                 output_tokens: -5,
                 cost_millicents: -25
               })

      assert message == "cannot correct a correction"

      # No second-level correction row was written.
      corrections_of_correction =
        Report
        |> where([r], r.corrects_report_id == ^correction.id)
        |> AdminRepo.all()

      assert corrections_of_correction == []
    end
  end

  describe "create_correction/4 concurrency safety (tokens-02)" do
    test "concurrent corrections on the same story: exactly one wins, total never negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      # story total: cost 2500. Two racing corrections of -2000 each would each
      # pass validation against the PRE-correction total (2500 - 2000 = 500 >= 0)
      # but together (2500 - 4000) are impossible. The per-story advisory lock
      # serializes them so the loser re-reads the winner's committed total and is
      # rejected — the total can never be driven negative.
      original = create_report(tenant.id, story, agent, project)

      corr = fn ->
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: 0,
          output_tokens: 0,
          cost_millicents: -2000
        })
      end

      # Task.async propagates $callers, so the sandbox connection is shared with
      # the racing tasks (mirrors orchestrator_test.exs optimistic-locking race).
      results =
        [Task.async(corr), Task.async(corr)]
        |> Task.await_many(5_000)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      rejects = Enum.filter(results, &match?({:error, :unprocessable_entity, _}, &1))

      assert length(successes) == 1
      assert length(rejects) == 1

      {:ok, totals} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert totals.total_cost_millicents == 500
      assert totals.total_cost_millicents >= 0
    end

    test "takes a per-story advisory lock so concurrent corrections serialize" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      test_pid = self()
      handler_id = "tokens-02-lock-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :admin_repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query =~ "pg_advisory_xact_lock" do
            send(test_pid, {:advisory_lock_query, query})
          end
        end,
        nil
      )

      try do
        assert {:ok, _correction} =
                 TokenUsage.create_correction(tenant.id, original.id, %{
                   input_tokens: -100,
                   output_tokens: -50,
                   cost_millicents: -250
                 })
      after
        :telemetry.detach(handler_id)
      end

      # The correction transaction MUST acquire the per-story advisory xact lock
      # that serializes concurrent corrections. If the lock step is removed, no
      # such query runs under READ COMMITTED and two racing corrections could
      # both pass validation — this assertion fails, catching that regression.
      assert_receive {:advisory_lock_query, _}, 500
    end

    test "serialized over-subtraction is rejected; the story total never goes negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      # story total: cost 2500, input 1000, output 500
      original = create_report(tenant.id, story, agent, project)

      # First correction zeroes the story out -> total 0.
      assert {:ok, _} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: -1000,
                 output_tokens: -500,
                 cost_millicents: -2500
               })

      {:ok, after_first} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert after_first.total_cost_millicents == 0

      # A SECOND correction (the double-submit/retry twin) that would subtract the
      # same amount again must re-read the now-updated total and be rejected. The
      # advisory lock forces this re-read under concurrency, so exactly one of two
      # racing corrections wins and the total can never be driven negative.
      assert {:error, :unprocessable_entity, message} =
               TokenUsage.create_correction(tenant.id, original.id, %{
                 input_tokens: 0,
                 output_tokens: 0,
                 cost_millicents: -2500
               })

      assert message =~ "cost_millicents"

      {:ok, final} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert final.total_cost_millicents == 0
      assert final.total_cost_millicents >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # tokens-04: soft-deleting an original must not strand its negative correction
  # ---------------------------------------------------------------------------

  describe "soft-delete total consistency (tokens-04)" do
    test "soft-deleting an original excludes its negative correction (total never negative)" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      # original: cost 2500, input 1000, output 500
      original = create_report(tenant.id, story, agent, project)

      {:ok, _correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      # Both live: 2500 - 250 = 2250
      {:ok, before} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert before.total_cost_millicents == 2250

      # Soft-delete the ORIGINAL. Its surviving negative correction must NOT be
      # counted on its own — that would strand it and drive the total to -250.
      {:ok, _} = TokenUsage.delete_report(tenant.id, original.id)

      {:ok, after_delete} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert after_delete.total_cost_millicents == 0
      assert after_delete.total_input_tokens == 0
      assert after_delete.total_output_tokens == 0
      assert after_delete.total_cost_millicents >= 0
      # The correction is excluded from the count as well.
      assert after_delete.report_count == 0
    end

    test "a correction whose original is live still counts normally" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      original = create_report(tenant.id, story, agent, project)

      {:ok, _correction} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: -100,
          output_tokens: -50,
          cost_millicents: -250
        })

      {:ok, totals} = TokenUsage.get_story_totals(tenant.id, story.id)
      assert totals.total_cost_millicents == 2250
      assert totals.total_input_tokens == 900
      assert totals.total_output_tokens == 450
      assert totals.report_count == 2
    end

    test "story/epic/project scope spend all exclude a stranded correction" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      original = create_report(tenant.id, story, agent, project)

      {:ok, _} =
        TokenUsage.create_correction(tenant.id, original.id, %{
          input_tokens: 0,
          output_tokens: 0,
          cost_millicents: -250
        })

      {:ok, _} = TokenUsage.delete_report(tenant.id, original.id)

      assert TokenUsage.get_scope_spend(tenant.id, :story, story.id) == 0
      assert TokenUsage.get_scope_spend(tenant.id, :epic, epic.id) == 0
      assert TokenUsage.get_scope_spend(tenant.id, :project, project.id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # tokens-05: threshold_crossed audit rows are deduplicated per real crossing
  # ---------------------------------------------------------------------------

  describe "threshold_crossed audit dedup (tokens-05)" do
    test "first warning crossing writes ONE audit; subsequent over-warning reports write none" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # First report crosses the warning threshold (8500/10000 = 85%).
      create_report(tenant.id, story, agent, project, %{cost_millicents: 8_500})
      assert count_threshold_audits(tenant.id, "warning") == 1

      # Further reports while STILL over the warning threshold must NOT write
      # another threshold_crossed audit row (the bug wrote one on every report).
      create_report(tenant.id, story, agent, project, %{cost_millicents: 200})
      create_report(tenant.id, story, agent, project, %{cost_millicents: 200})
      assert count_threshold_audits(tenant.id, "warning") == 1
    end

    test "crossing 100% after only warning writes the exceeded audit exactly once" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Cross warning only (85%).
      create_report(tenant.id, story, agent, project, %{cost_millicents: 8_500})
      assert count_threshold_audits(tenant.id, "warning") == 1
      assert count_threshold_audits(tenant.id, "exceeded") == 0

      # Now cross 100% — a GENUINE new crossing writes the exceeded audit once.
      create_report(tenant.id, story, agent, project, %{cost_millicents: 3_000})
      assert count_threshold_audits(tenant.id, "exceeded") == 1
      assert count_threshold_audits(tenant.id, "warning") == 1

      # A further over-100% report writes NO additional audit rows.
      create_report(tenant.id, story, agent, project, %{cost_millicents: 500})
      assert count_threshold_audits(tenant.id, "exceeded") == 1
      assert count_threshold_audits(tenant.id, "warning") == 1
    end

    test "a single report crossing BOTH thresholds writes one warning and one exceeded" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # 6000/5000 = 120% crosses warning AND exceeded at once.
      create_report(tenant.id, story, agent, project, %{cost_millicents: 6_000})
      assert count_threshold_audits(tenant.id, "warning") == 1
      assert count_threshold_audits(tenant.id, "exceeded") == 1

      create_report(tenant.id, story, agent, project, %{cost_millicents: 500})
      assert count_threshold_audits(tenant.id, "warning") == 1
      assert count_threshold_audits(tenant.id, "exceeded") == 1
    end

    test "reset semantics: after spend drops below threshold, a re-crossing writes a new audit" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      report = create_report(tenant.id, story, agent, project, %{cost_millicents: 8_500})
      assert count_threshold_audits(tenant.id, "warning") == 1

      # Drop spend far below the warning threshold via a correction — this resets
      # warning_fired (same reset path the webhook dedup uses).
      {:ok, _} =
        TokenUsage.create_correction(tenant.id, report.id, %{
          input_tokens: 0,
          output_tokens: 0,
          cost_millicents: -8_000
        })

      # Re-cross the warning threshold — a NEW crossing writes another audit row.
      create_report(tenant.id, story, agent, project, %{cost_millicents: 8_000})
      assert count_threshold_audits(tenant.id, "warning") == 2
    end
  end
end
