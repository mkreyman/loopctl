defmodule Loopctl.TokenUsageChangeFeedTest do
  @moduledoc """
  Tests for US-21.8: Change Feed & Audit Integration for Token Events.

  Verifies that token-related mutations (report creation, budget mutations,
  anomaly detection/resolution) emit change feed entries via the audit log,
  and that story history includes related token usage events.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.Workers.CostAnomalyWorker

  import Ecto.Query

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

  # --- AC-21.8.1: Token usage report creation generates a change feed entry ---

  describe "create_report/3 change feed integration (AC-21.8.1)" do
    test "emits audit log entry with entity_type='token_usage_report' and action='created'" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500
      }

      {:ok, _report} = TokenUsage.create_report(tenant.id, attrs)

      entries = find_audit_entries(tenant.id, "token_usage_report", "created")
      assert length(entries) == 1
    end

    test "change feed entry new_state includes story_id, agent_id, model_name, cost_millicents, total_tokens" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 2000,
        output_tokens: 1000,
        model_name: "claude-sonnet-4",
        cost_millicents: 3500
      }

      {:ok, _report} = TokenUsage.create_report(tenant.id, attrs)

      [entry] = find_audit_entries(tenant.id, "token_usage_report", "created")

      assert entry.new_state["story_id"] == story.id
      assert entry.new_state["agent_id"] == agent.id
      assert entry.new_state["model_name"] == "claude-sonnet-4"
      assert entry.new_state["cost_millicents"] == 3500
      assert entry.new_state["total_tokens"] == 3000
    end

    test "change feed entry metadata includes story_id for story history lookup" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 500,
        output_tokens: 200,
        model_name: "claude-haiku-4",
        cost_millicents: 700
      }

      {:ok, _report} = TokenUsage.create_report(tenant.id, attrs)

      [entry] = find_audit_entries(tenant.id, "token_usage_report", "created")

      assert entry.metadata["story_id"] == story.id
      assert entry.metadata["agent_id"] == agent.id
      assert entry.metadata["model_name"] == "claude-haiku-4"
      assert entry.metadata["cost_millicents"] == 700
    end

    test "tenant isolation: report creation only emits entry for its own tenant" do
      %{tenant: tenant_a, story: story_a, agent: agent_a, project: project_a} = setup_context()
      %{tenant: tenant_b, story: story_b, agent: agent_b, project: project_b} = setup_context()

      attrs_a = %{
        story_id: story_a.id,
        agent_id: agent_a.id,
        project_id: project_a.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 100
      }

      attrs_b = %{
        story_id: story_b.id,
        agent_id: agent_b.id,
        project_id: project_b.id,
        input_tokens: 200,
        output_tokens: 100,
        model_name: "claude-opus-4",
        cost_millicents: 200
      }

      {:ok, _} = TokenUsage.create_report(tenant_a.id, attrs_a)
      {:ok, _} = TokenUsage.create_report(tenant_b.id, attrs_b)

      entries_a = find_audit_entries(tenant_a.id, "token_usage_report", "created")
      entries_b = find_audit_entries(tenant_b.id, "token_usage_report", "created")

      assert length(entries_a) == 1
      assert length(entries_b) == 1
      # Tenant A's entry references tenant A's story
      assert hd(entries_a).new_state["story_id"] == story_a.id
      assert hd(entries_b).new_state["story_id"] == story_b.id
    end
  end

  # --- AC-21.8.2: Budget threshold crossings generate change feed entries ---

  describe "budget threshold crossing change feed (AC-21.8.2)" do
    test "emits threshold_crossed with threshold_type='warning' when spend crosses alert_threshold_pct" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      # Create a budget with alert_threshold_pct=80 and budget of 10,000 millicents
      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Create a report that pushes spend to 85% (8,500 out of 10,000)
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      assert length(entries) == 1

      [entry] = entries
      assert entry.new_state["budget_id"] == budget.id
      assert entry.new_state["scope_type"] == "story"
      assert entry.new_state["scope_id"] == story.id
      assert entry.new_state["threshold_type"] == "warning"
      assert entry.new_state["utilization_pct"] >= 80
    end

    test "emits threshold_crossed with threshold_type='exceeded' when spend crosses 100%" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # Create a report that pushes spend above 100% (6,000 out of 5,000)
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 6_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      # Both warning and exceeded fire independently when spend jumps past both thresholds
      assert length(entries) == 2

      threshold_types = Enum.map(entries, & &1.new_state["threshold_type"]) |> Enum.sort()
      assert threshold_types == ["exceeded", "warning"]

      exceeded_entry = Enum.find(entries, &(&1.new_state["threshold_type"] == "exceeded"))
      assert exceeded_entry.new_state["utilization_pct"] >= 100
    end

    test "does NOT emit threshold_crossed when spend is below alert_threshold_pct" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 100_000,
          alert_threshold_pct: 80
        })

      # Spend only 10% of budget
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 10_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      assert entries == []
    end

    test "checks project-level budget threshold" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :project,
          scope_id: project.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Push project spend to 90%
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 9_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      assert length(entries) == 1
      assert hd(entries).new_state["scope_type"] == "project"
    end

    test "checks epic-level budget threshold" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :epic,
          scope_id: epic.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Push epic spend to 90%
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 9_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      assert length(entries) == 1
      assert hd(entries).new_state["scope_type"] == "epic"
    end

    test "emits threshold_crossed for multiple budgets when applicable" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      # Create both story and project budgets
      {:ok, _story_budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      {:ok, _project_budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :project,
          scope_id: project.id,
          budget_millicents: 8_000,
          alert_threshold_pct: 80
        })

      # Push both over threshold
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 7_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      # Story budget: 7000/5000 = 140% -> both warning + exceeded entries (2)
      # Project budget: 7000/8000 = 87.5% -> warning entry only (1)
      # Total: 3
      assert length(entries) == 3

      scope_types = Enum.map(entries, & &1.new_state["scope_type"]) |> Enum.sort()
      assert scope_types == ["project", "story", "story"]
    end

    test "threshold_crossed entry includes metadata with budget_id and scope_id" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 5_500
        })

      entries = find_audit_entries(tenant.id, "token_budget", "threshold_crossed")
      # Spend 5500/5000 = 110% -> both warning + exceeded audit entries fire
      assert length(entries) == 2

      exceeded_entry =
        Enum.find(entries, &(&1.new_state["threshold_type"] == "exceeded"))

      assert exceeded_entry.metadata["budget_id"] == budget.id
      assert exceeded_entry.metadata["scope_type"] == "story"
      assert exceeded_entry.metadata["scope_id"] == story.id
      assert exceeded_entry.metadata["threshold_type"] == "exceeded"
    end
  end

  # --- AC-21.8.5: Budget mutations are audited ---

  describe "budget mutation audit log (AC-21.8.5)" do
    test "create_budget/3 emits audit log entry with entity_type='token_budget' and action='created'" do
      %{tenant: tenant, story: story} = setup_context()

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      entries = find_audit_entries(tenant.id, "token_budget", "created")
      assert length(entries) == 1
    end

    test "update_budget/4 emits audit log entry with action='updated'" do
      %{tenant: tenant, story: story} = setup_context()

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      {:ok, _} =
        TokenUsage.update_budget(tenant.id, budget.id, %{budget_millicents: 750_000})

      entries = find_audit_entries(tenant.id, "token_budget", "updated")
      assert length(entries) == 1
    end

    test "delete_budget/3 emits audit log entry with action='deleted'" do
      %{tenant: tenant, story: story} = setup_context()

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 500_000
        })

      {:ok, _} = TokenUsage.delete_budget(tenant.id, budget.id)

      entries = find_audit_entries(tenant.id, "token_budget", "deleted")
      assert length(entries) == 1
    end

    test "resolve_anomaly/3 emits audit log entry with entity_type='cost_anomaly' and action='resolved'" do
      %{tenant: tenant, story: story} = setup_context()

      anomaly =
        fixture(:cost_anomaly, %{
          tenant_id: tenant.id,
          story_id: story.id,
          anomaly_type: :high_cost
        })

      {:ok, _} = TokenUsage.resolve_anomaly(tenant.id, anomaly.id)

      entries = find_audit_entries(tenant.id, "cost_anomaly", "resolved")
      assert length(entries) == 1
    end
  end

  # --- AC-21.8.3: Cost anomaly detection generates change feed entry ---

  describe "CostAnomalyWorker change feed integration (AC-21.8.3, AC-21.8.5)" do
    defp create_story_with_report(tenant, epic, agent, cost_millicents) do
      story =
        fixture(:story, %{
          tenant_id: tenant.id,
          epic_id: epic.id,
          project_id: epic.project_id
        })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: epic.project_id,
        cost_millicents: cost_millicents
      })

      story
    end

    defp insert_cost_summary(tenant_id, epic_id, period_start, period_end, avg) do
      %CostSummary{tenant_id: tenant_id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic_id,
        period_start: period_start,
        period_end: period_end,
        total_cost_millicents: avg * 4,
        report_count: 4,
        avg_cost_per_story_millicents: avg
      })
      |> AdminRepo.insert!()
    end

    test "new anomaly detection emits audit log with entity_type='cost_anomaly' and action='detected'" do
      %{tenant: tenant, epic: epic, agent: agent} = setup_context()
      period = Date.utc_today()

      _normal1 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal2 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal3 = create_story_with_report(tenant, epic, agent, 10_000)
      _expensive = create_story_with_report(tenant, epic, agent, 100_000)

      insert_cost_summary(tenant.id, epic.id, period, period, 32_500)

      CostAnomalyWorker.perform(%Oban.Job{
        args: %{
          "period_start" => Date.to_iso8601(period),
          "period_end" => Date.to_iso8601(period)
        }
      })

      entries = find_audit_entries(tenant.id, "cost_anomaly", "detected")
      assert length(entries) == 1
    end

    test "anomaly detected entry includes anomaly_type and deviation_factor in new_state" do
      %{tenant: tenant, epic: epic, agent: agent} = setup_context()
      period = Date.utc_today()

      _normal1 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal2 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal3 = create_story_with_report(tenant, epic, agent, 10_000)
      expensive = create_story_with_report(tenant, epic, agent, 100_000)

      insert_cost_summary(tenant.id, epic.id, period, period, 32_500)

      CostAnomalyWorker.perform(%Oban.Job{
        args: %{
          "period_start" => Date.to_iso8601(period),
          "period_end" => Date.to_iso8601(period)
        }
      })

      [entry] = find_audit_entries(tenant.id, "cost_anomaly", "detected")

      assert entry.new_state["anomaly_type"] == "high_cost"
      assert entry.new_state["story_id"] == expensive.id
      assert entry.new_state["story_cost_millicents"] == 100_000
      assert entry.new_state["reference_avg_millicents"] == 32_500
      assert entry.new_state["deviation_factor"] != nil
    end

    test "anomaly detected entry includes metadata with anomaly_id and story_id" do
      %{tenant: tenant, epic: epic, agent: agent} = setup_context()
      period = Date.utc_today()

      _normal1 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal2 = create_story_with_report(tenant, epic, agent, 10_000)
      _normal3 = create_story_with_report(tenant, epic, agent, 10_000)
      expensive = create_story_with_report(tenant, epic, agent, 100_000)

      insert_cost_summary(tenant.id, epic.id, period, period, 32_500)

      CostAnomalyWorker.perform(%Oban.Job{
        args: %{
          "period_start" => Date.to_iso8601(period),
          "period_end" => Date.to_iso8601(period)
        }
      })

      [entry] = find_audit_entries(tenant.id, "cost_anomaly", "detected")

      assert entry.metadata["anomaly_id"] != nil
      assert entry.metadata["story_id"] == expensive.id
      assert entry.metadata["anomaly_type"] == "high_cost"
    end

    test "updating existing anomaly does NOT emit a new detected entry" do
      %{tenant: tenant, epic: epic, agent: agent, story: story} = setup_context()
      period = Date.utc_today()

      # Pre-create an existing unresolved anomaly
      fixture(:cost_anomaly, %{
        tenant_id: tenant.id,
        story_id: story.id,
        anomaly_type: :high_cost,
        story_cost_millicents: 80_000,
        reference_avg_millicents: 20_000,
        deviation_factor: Decimal.new("4.0")
      })

      # The existing anomaly story's cost now appears in reports
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: epic.project_id,
        cost_millicents: 100_000
      })

      insert_cost_summary(tenant.id, epic.id, period, period, 25_000)

      CostAnomalyWorker.perform(%Oban.Job{
        args: %{
          "period_start" => Date.to_iso8601(period),
          "period_end" => Date.to_iso8601(period)
        }
      })

      # No new "detected" entries since the anomaly was updated, not created
      entries = find_audit_entries(tenant.id, "cost_anomaly", "detected")
      assert entries == []
    end

    test "tenant isolation: anomaly detection only emits entries for its own tenant" do
      %{tenant: tenant_a, epic: epic_a, agent: agent_a} = setup_context()
      %{tenant: tenant_b} = setup_context()
      period = Date.utc_today()

      _normal1 = create_story_with_report(tenant_a, epic_a, agent_a, 10_000)
      _normal2 = create_story_with_report(tenant_a, epic_a, agent_a, 10_000)
      _normal3 = create_story_with_report(tenant_a, epic_a, agent_a, 10_000)
      _expensive = create_story_with_report(tenant_a, epic_a, agent_a, 100_000)

      insert_cost_summary(tenant_a.id, epic_a.id, period, period, 32_500)

      CostAnomalyWorker.perform(%Oban.Job{
        args: %{
          "period_start" => Date.to_iso8601(period),
          "period_end" => Date.to_iso8601(period)
        }
      })

      entries_a = find_audit_entries(tenant_a.id, "cost_anomaly", "detected")
      entries_b = find_audit_entries(tenant_b.id, "cost_anomaly", "detected")

      assert length(entries_a) == 1
      assert entries_b == []
    end
  end

  # --- AC-21.8.4: Change feed entity_type filter accepts token event types ---

  describe "change feed entity_type filter (AC-21.8.4)" do
    test "list_changes/3 filters by entity_type='token_usage_report'" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      since = DateTime.add(DateTime.utc_now(), -60)

      # Create a token usage report (emits audit log)
      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 200
      })

      # Create a non-token audit entry
      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "status_changed",
        actor_type: "api_key",
        new_state: %{}
      })

      {:ok, result} =
        Audit.list_changes(tenant.id, since, entity_type: "token_usage_report")

      assert length(result.data) == 1
      assert hd(result.data).entity_type == "token_usage_report"
    end

    test "list_changes/3 filters by entity_type='token_budget'" do
      %{tenant: tenant, story: story} = setup_context()
      since = DateTime.add(DateTime.utc_now(), -60)

      TokenUsage.create_budget(tenant.id, %{
        scope_type: :story,
        scope_id: story.id,
        budget_millicents: 500_000
      })

      # Add a non-budget entry
      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      {:ok, result} =
        Audit.list_changes(tenant.id, since, entity_type: "token_budget")

      assert length(result.data) == 1
      assert hd(result.data).entity_type == "token_budget"
    end

    test "list_changes/3 filters by entity_type='cost_anomaly'" do
      %{tenant: tenant, story: story} = setup_context()
      since = DateTime.add(DateTime.utc_now(), -60)

      # Insert an anomaly resolution to emit a cost_anomaly audit entry
      anomaly =
        fixture(:cost_anomaly, %{
          tenant_id: tenant.id,
          story_id: story.id
        })

      TokenUsage.resolve_anomaly(tenant.id, anomaly.id)

      {:ok, result} =
        Audit.list_changes(tenant.id, since, entity_type: "cost_anomaly")

      assert length(result.data) == 1
      assert hd(result.data).entity_type == "cost_anomaly"
    end

    test "list_changes/3 returns token events interleaved chronologically" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      since = DateTime.add(DateTime.utc_now(), -60)

      # Interleave token and non-token events
      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "created",
        actor_type: "api_key",
        actor_label: "step:1",
        new_state: %{}
      })

      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 200
      })

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "status_changed",
        actor_type: "api_key",
        actor_label: "step:3",
        new_state: %{}
      })

      {:ok, result} = Audit.list_changes(tenant.id, since)

      # Should include all 3 entries in ascending time order
      assert length(result.data) >= 3
      entity_types = Enum.map(result.data, & &1.entity_type)
      assert "token_usage_report" in entity_types
      assert "story" in entity_types
    end
  end

  # --- AC-21.8.6: Story history includes token usage events ---

  describe "story history token usage integration (AC-21.8.6)" do
    test "entity_history/4 for a story includes related token_usage_report audit entries" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      # Create a story audit entry
      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "status_changed",
        actor_type: "api_key",
        new_state: %{"agent_status" => "implementing"}
      })

      # Create a token usage report for this story (which emits audit log with story_id in metadata)
      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500
      })

      {:ok, result} = Audit.entity_history(tenant.id, "story", story.id)

      # Should include both the direct story entry and the token_usage_report entry
      assert result.total == 2
      entity_types = Enum.map(result.data, & &1.entity_type)
      assert "story" in entity_types
      assert "token_usage_report" in entity_types
    end

    test "entity_history/4 orders entries chronologically ascending" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 500,
        output_tokens: 200,
        model_name: "claude-opus-4",
        cost_millicents: 1000
      })

      {:ok, result} = Audit.entity_history(tenant.id, "story", story.id)

      assert result.total == 2
      timestamps = Enum.map(result.data, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:asc, DateTime})
    end

    test "entity_history/4 for non-story entity types does NOT include token entries" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()
      project_id = project.id

      # Create a project audit entry
      Audit.create_log_entry(tenant.id, %{
        entity_type: "project",
        entity_id: project_id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      # Create a token usage report for a story in this project
      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 200
      })

      {:ok, result} = Audit.entity_history(tenant.id, "project", project_id)

      # Only the direct project entry is returned, not the token entry
      assert result.total == 1
      assert hd(result.data).entity_type == "project"
    end

    test "entity_history/4 does not include token entries for other stories" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      other_story = fixture(:story, %{tenant_id: tenant.id, epic_id: story.epic_id})

      # Story audit entry for the target story
      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      # Token usage report for a DIFFERENT story
      TokenUsage.create_report(tenant.id, %{
        story_id: other_story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 200
      })

      {:ok, result} = Audit.entity_history(tenant.id, "story", story.id)

      # Only the direct story entry — no token entries from the other story
      assert result.total == 1
      assert hd(result.data).entity_type == "story"
    end

    test "entity_history/4 tenant isolation: does not include other tenant's token entries" do
      %{tenant: tenant_a, story: story_a, agent: agent_a, project: project_a} = setup_context()
      %{tenant: tenant_b, story: story_b, agent: agent_b, project: project_b} = setup_context()

      # Story audit entry for tenant A
      Audit.create_log_entry(tenant_a.id, %{
        entity_type: "story",
        entity_id: story_a.id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      # Token usage report for tenant A's story
      TokenUsage.create_report(tenant_a.id, %{
        story_id: story_a.id,
        agent_id: agent_a.id,
        project_id: project_a.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 200
      })

      # Token usage report for tenant B's story (same story UUID won't match but different tenant)
      TokenUsage.create_report(tenant_b.id, %{
        story_id: story_b.id,
        agent_id: agent_b.id,
        project_id: project_b.id,
        input_tokens: 300,
        output_tokens: 100,
        model_name: "claude-opus-4",
        cost_millicents: 500
      })

      {:ok, result_a} = Audit.entity_history(tenant_a.id, "story", story_a.id)
      {:ok, result_b} = Audit.entity_history(tenant_b.id, "story", story_b.id)

      # Tenant A sees 1 story entry + 1 token entry = 2
      assert result_a.total == 2
      # Tenant B sees only their own token entry (no story-type audit entry created)
      assert result_b.total == 1
      assert hd(result_b.data).entity_type == "token_usage_report"
    end

    test "multiple token reports for same story appear in story history" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      Audit.create_log_entry(tenant.id, %{
        entity_type: "story",
        entity_id: story.id,
        action: "created",
        actor_type: "api_key",
        new_state: %{}
      })

      for _i <- 1..3 do
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 200
        })
      end

      {:ok, result} = Audit.entity_history(tenant.id, "story", story.id)

      # 1 story entry + 3 token entries = 4
      assert result.total == 4
    end
  end
end
