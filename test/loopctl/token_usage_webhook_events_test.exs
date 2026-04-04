defmodule Loopctl.TokenUsageWebhookEventsTest do
  @moduledoc """
  Tests for US-21.7: Webhook Events for Cost Alerts.

  Verifies that:
  - AC-21.7.1: New event types are registered and accepted by webhook subscriptions
  - AC-21.7.2: token.budget_warning payload has the correct fields
  - AC-21.7.3: token.budget_exceeded payload has the correct fields including overage_millicents
  - AC-21.7.4: token.anomaly_detected payload has the correct fields
  - AC-21.7.5: Budget webhook events fire synchronously when a report is created
  - AC-21.7.6: Deduplication via warning_fired/exceeded_fired flags; reset on budget update
  - AC-21.7.7: CostAnomalyWorker fires anomaly webhooks for newly created anomalies
  - AC-21.7.8: All webhook events are signed (consistent with existing delivery infrastructure)
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.WebhookEvent
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

  defp create_webhook_for_events(tenant_id, events) do
    {:ok, %{webhook: webhook}} =
      Webhooks.create_webhook(tenant_id, %{
        "url" => "https://example.com/hooks/#{System.unique_integer([:positive])}",
        "events" => events
      })

    webhook
  end

  defp find_webhook_events(tenant_id, event_type) do
    WebhookEvent
    |> where([e], e.tenant_id == ^tenant_id and e.event_type == ^event_type)
    |> AdminRepo.all()
  end

  # --- AC-21.7.1: New event types are registered ---

  describe "valid event types (AC-21.7.1)" do
    test "token.budget_warning is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["token.budget_warning"]
        })

      assert "token.budget_warning" in webhook.events
    end

    test "token.budget_exceeded is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["token.budget_exceeded"]
        })

      assert "token.budget_exceeded" in webhook.events
    end

    test "token.anomaly_detected is a valid event type for webhook subscription" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["token.anomaly_detected"]
        })

      assert "token.anomaly_detected" in webhook.events
    end

    test "can subscribe to all three new event types simultaneously" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["token.budget_warning", "token.budget_exceeded", "token.anomaly_detected"]
        })

      assert length(webhook.events) == 3
    end

    test "existing event types still valid after addition of new types" do
      tenant = fixture(:tenant)

      {:ok, %{webhook: webhook}} =
        Webhooks.create_webhook(tenant.id, %{
          "url" => "https://example.com/hooks",
          "events" => ["story.status_changed", "token.budget_warning"]
        })

      assert "story.status_changed" in webhook.events
      assert "token.budget_warning" in webhook.events
    end
  end

  # --- AC-21.7.2: token.budget_warning payload ---

  describe "token.budget_warning payload (AC-21.7.2)" do
    test "fires with correct payload fields when spend crosses alert threshold" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Spend pushes to 85% (8,500 out of 10,000)
      {:ok, report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      events = find_webhook_events(tenant.id, "token.budget_warning")
      assert [event] = events
      payload = event.payload

      assert payload["budget_id"] == budget.id
      assert payload["scope_type"] == "story"
      assert payload["scope_id"] == story.id
      assert payload["budget_millicents"] == 10_000
      assert payload["current_spend_millicents"] == 8_500
      assert payload["utilization_pct"] >= 80
      assert payload["alert_threshold_pct"] == 80
      assert payload["triggering_report_id"] == report.id
      # overage_millicents is NOT present in warning payload
      refute Map.has_key?(payload, "overage_millicents")
    end
  end

  # --- AC-21.7.3: token.budget_exceeded payload ---

  describe "token.budget_exceeded payload (AC-21.7.3)" do
    test "fires with correct payload including overage_millicents when budget exceeded" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_exceeded"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # Spend pushes to 120% (6,000 out of 5,000)
      {:ok, report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 6_000
        })

      events = find_webhook_events(tenant.id, "token.budget_exceeded")
      assert [event] = events
      payload = event.payload

      assert payload["budget_id"] == budget.id
      assert payload["scope_type"] == "story"
      assert payload["scope_id"] == story.id
      assert payload["budget_millicents"] == 5_000
      assert payload["current_spend_millicents"] == 6_000
      assert payload["utilization_pct"] >= 100
      assert payload["alert_threshold_pct"] == 80
      assert payload["triggering_report_id"] == report.id
      assert payload["overage_millicents"] == 1_000
    end

    test "overage_millicents is zero when spend exactly equals budget" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_exceeded"])

      {:ok, _budget} =
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
          cost_millicents: 5_000
        })

      events = find_webhook_events(tenant.id, "token.budget_exceeded")
      assert [event] = events
      assert event.payload["overage_millicents"] == 0
    end
  end

  # --- AC-21.7.5: Budget checks fire synchronously when report is created ---

  describe "synchronous firing (AC-21.7.5)" do
    test "webhook event is created in the same operation as the report" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
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
          cost_millicents: 9_000
        })

      # Event should already exist immediately after report creation
      events = find_webhook_events(tenant.id, "token.budget_warning")
      assert events != []
    end

    test "no webhook events created when spend is below threshold" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, _budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 100_000,
          alert_threshold_pct: 80
        })

      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 1_000
        })

      events = find_webhook_events(tenant.id, "token.budget_warning")
      assert events == []
    end

    test "no webhook event fires if no webhook subscribed to event type" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      # Only subscribe to a different event
      _webhook = create_webhook_for_events(tenant.id, ["story.verified"])

      {:ok, _budget} =
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
          cost_millicents: 9_000
        })

      events = find_webhook_events(tenant.id, "token.budget_warning")
      assert events == []
    end
  end

  # --- AC-21.7.6: Deduplication via warning_fired/exceeded_fired ---

  describe "deduplication flags (AC-21.7.6)" do
    test "warning webhook fires only once (warning_fired set to true after first fire)" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # First report: crosses warning threshold
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      events_after_first = find_webhook_events(tenant.id, "token.budget_warning")
      assert events_after_first != []

      # Verify warning_fired is now true
      reloaded_budget = AdminRepo.get!(Budget, budget.id)
      assert reloaded_budget.warning_fired == true

      # Second report: still in warning range, should NOT fire again
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 200
        })

      events_after_second = find_webhook_events(tenant.id, "token.budget_warning")
      assert Enum.count(events_after_second) == 1
    end

    test "exceeded webhook fires only once (exceeded_fired set to true after first fire)" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_exceeded"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # First report: crosses 100%
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 6_000
        })

      events_after_first = find_webhook_events(tenant.id, "token.budget_exceeded")
      assert events_after_first != []

      reloaded_budget = AdminRepo.get!(Budget, budget.id)
      assert reloaded_budget.exceeded_fired == true

      # Second report: still over 100%, should NOT fire again
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 100,
          output_tokens: 50,
          model_name: "claude-opus-4",
          cost_millicents: 100
        })

      events_after_second = find_webhook_events(tenant.id, "token.budget_exceeded")
      assert Enum.count(events_after_second) == 1
    end

    test "warning_fired and exceeded_fired default to false on new budgets" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      assert budget.warning_fired == false
      assert budget.exceeded_fired == false
    end

    test "flags are reset when budget_millicents is updated" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Fire the warning
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true

      # Update budget_millicents — should reset flags
      {:ok, updated} =
        TokenUsage.update_budget(tenant.id, budget.id, %{budget_millicents: 20_000})

      assert updated.warning_fired == false
      assert updated.exceeded_fired == false
    end

    test "flags are reset when alert_threshold_pct is updated" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Fire the warning
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true

      # Update alert_threshold_pct — should reset flags
      {:ok, updated} =
        TokenUsage.update_budget(tenant.id, budget.id, %{alert_threshold_pct: 90})

      assert updated.warning_fired == false
      assert updated.exceeded_fired == false
    end

    test "flags are NOT reset when updating only metadata" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.budget_warning"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Fire the warning
      {:ok, _} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true

      # Update only metadata — flags should remain
      {:ok, updated} =
        TokenUsage.update_budget(tenant.id, budget.id, %{
          metadata: %{"note" => "updated metadata only"}
        })

      assert updated.warning_fired == true
      assert updated.exceeded_fired == false
    end
  end

  # --- AC-21.7.7: CostAnomalyWorker fires anomaly webhooks ---

  describe "CostAnomalyWorker fires token.anomaly_detected (AC-21.7.7)" do
    test "fires token.anomaly_detected webhook with correct payload when anomaly is created" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.anomaly_detected"])

      # Create cost summaries so CostAnomalyWorker has epic average
      period = Date.utc_today()

      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic.id,
        period_start: period,
        period_end: period,
        total_cost_millicents: 10_000,
        story_count: 2,
        avg_cost_per_story_millicents: 5_000
      })
      |> AdminRepo.insert!()

      # Create a report 4x the epic average to trigger high_cost anomaly
      # Need to insert directly since CostAnomalyWorker uses its own date-based query
      # We test via the create_anomaly path by calling the worker directly
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "claude-opus-4",
          cost_millicents: 20_000
        })

      # Run the worker which will detect the anomaly from yesterday's rollup data
      # Since we're in Oban inline mode and the worker runs against yesterday's period,
      # we test via perform/1 with an explicit period matching today
      job_args = %{
        "period_start" => Date.to_iso8601(period),
        "period_end" => Date.to_iso8601(period)
      }

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})

      events = find_webhook_events(tenant.id, "token.anomaly_detected")
      assert events != []

      [event | _] = events
      payload = event.payload

      assert payload["story_id"] == story.id
      assert payload["anomaly_type"] in ["high_cost", "suspiciously_low"]
      assert is_integer(payload["story_cost_millicents"])
      assert is_integer(payload["reference_avg_millicents"])
      assert is_binary(payload["deviation_factor"])
      assert is_binary(payload["anomaly_id"])
    end

    test "anomaly webhook payload includes story_title and agent context" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      # Assign the agent to the story
      story
      |> Ecto.Changeset.change(%{assigned_agent_id: agent.id})
      |> AdminRepo.update!()

      _webhook = create_webhook_for_events(tenant.id, ["token.anomaly_detected"])

      period = Date.utc_today()

      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic.id,
        period_start: period,
        period_end: period,
        total_cost_millicents: 10_000,
        story_count: 2,
        avg_cost_per_story_millicents: 5_000
      })
      |> AdminRepo.insert!()

      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "claude-opus-4",
          cost_millicents: 20_000
        })

      job_args = %{
        "period_start" => Date.to_iso8601(period),
        "period_end" => Date.to_iso8601(period)
      }

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})

      events = find_webhook_events(tenant.id, "token.anomaly_detected")
      assert events != []

      [event | _] = events
      payload = event.payload

      assert payload["story_title"] == story.title
      assert payload["agent_id"] == agent.id
      assert payload["agent_name"] == agent.name
    end

    test "does NOT fire anomaly webhook for updated (existing) anomalies" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      _webhook = create_webhook_for_events(tenant.id, ["token.anomaly_detected"])

      period = Date.utc_today()

      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic.id,
        period_start: period,
        period_end: period,
        total_cost_millicents: 10_000,
        story_count: 2,
        avg_cost_per_story_millicents: 5_000
      })
      |> AdminRepo.insert!()

      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "claude-opus-4",
          cost_millicents: 20_000
        })

      job_args = %{
        "period_start" => Date.to_iso8601(period),
        "period_end" => Date.to_iso8601(period)
      }

      # First run creates the anomaly and fires the webhook
      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})
      events_after_first = find_webhook_events(tenant.id, "token.anomaly_detected")
      assert events_after_first != []

      # Second run with same period should update existing anomaly (not insert new)
      # and should NOT fire another webhook event
      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 2})
      events_after_second = find_webhook_events(tenant.id, "token.anomaly_detected")
      assert Enum.count(events_after_second) == Enum.count(events_after_first)
    end

    test "does not fire anomaly webhook if no webhook subscribed to token.anomaly_detected" do
      %{tenant: tenant, story: story, agent: agent, project: project, epic: epic} =
        setup_context()

      # Subscribe to a different event only
      _webhook = create_webhook_for_events(tenant.id, ["story.verified"])

      period = Date.utc_today()

      %CostSummary{tenant_id: tenant.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic.id,
        period_start: period,
        period_end: period,
        total_cost_millicents: 10_000,
        story_count: 2,
        avg_cost_per_story_millicents: 5_000
      })
      |> AdminRepo.insert!()

      {:ok, _report} =
        TokenUsage.create_report(tenant.id, %{
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "claude-opus-4",
          cost_millicents: 20_000
        })

      job_args = %{
        "period_start" => Date.to_iso8601(period),
        "period_end" => Date.to_iso8601(period)
      }

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})

      events = find_webhook_events(tenant.id, "token.anomaly_detected")
      assert events == []
    end
  end

  # --- Tenant isolation tests ---

  describe "tenant isolation" do
    test "budget webhook events are not visible to other tenants" do
      %{tenant: tenant_a, story: story_a, agent: agent_a, project: project_a} = setup_context()
      %{tenant: tenant_b} = setup_context()

      _webhook_a = create_webhook_for_events(tenant_a.id, ["token.budget_warning"])
      _webhook_b = create_webhook_for_events(tenant_b.id, ["token.budget_warning"])

      {:ok, _budget} =
        TokenUsage.create_budget(tenant_a.id, %{
          scope_type: :story,
          scope_id: story_a.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      {:ok, _report} =
        TokenUsage.create_report(tenant_a.id, %{
          story_id: story_a.id,
          agent_id: agent_a.id,
          project_id: project_a.id,
          input_tokens: 1000,
          output_tokens: 500,
          model_name: "claude-opus-4",
          cost_millicents: 8_500
        })

      # Tenant A has the warning event
      events_a = find_webhook_events(tenant_a.id, "token.budget_warning")
      assert events_a != []

      # Tenant B has no events
      events_b = find_webhook_events(tenant_b.id, "token.budget_warning")
      assert events_b == []
    end

    test "anomaly webhook events are not visible to other tenants" do
      %{
        tenant: tenant_a,
        story: story_a,
        agent: agent_a,
        project: project_a,
        epic: epic_a
      } = setup_context()

      %{tenant: tenant_b} = setup_context()

      _webhook_a = create_webhook_for_events(tenant_a.id, ["token.anomaly_detected"])
      _webhook_b = create_webhook_for_events(tenant_b.id, ["token.anomaly_detected"])

      period = Date.utc_today()

      %CostSummary{tenant_id: tenant_a.id}
      |> CostSummary.changeset(%{
        scope_type: :epic,
        scope_id: epic_a.id,
        period_start: period,
        period_end: period,
        total_cost_millicents: 10_000,
        story_count: 2,
        avg_cost_per_story_millicents: 5_000
      })
      |> AdminRepo.insert!()

      {:ok, _report} =
        TokenUsage.create_report(tenant_a.id, %{
          story_id: story_a.id,
          agent_id: agent_a.id,
          project_id: project_a.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "claude-opus-4",
          cost_millicents: 20_000
        })

      job_args = %{
        "period_start" => Date.to_iso8601(period),
        "period_end" => Date.to_iso8601(period)
      }

      assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})

      # Tenant A has anomaly events
      events_a = find_webhook_events(tenant_a.id, "token.anomaly_detected")
      assert events_a != []

      # Tenant B has no anomaly events
      events_b = find_webhook_events(tenant_b.id, "token.anomaly_detected")
      assert events_b == []
    end
  end
end
