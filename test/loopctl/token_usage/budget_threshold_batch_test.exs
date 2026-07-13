defmodule Loopctl.TokenUsage.BudgetThresholdBatchTest do
  @moduledoc """
  Tests for US-33.5: Reuse batch_attach_spend on the token-usage budget-threshold path.

  `check_budget_thresholds/2` now computes spend for ALL applicable budgets via the
  batched `batch_attach_spend/2` (one grouped GROUP BY query per distinct scope_type)
  — the SAME spend path `list_budgets/2` uses — instead of a divergent per-budget
  `get_scope_spend/3` single-row select loop. This is a BEHAVIOR-PRESERVING
  consolidation onto a single source of truth for countable spend: identical spend
  numbers, identical threshold crossings, identical side effects.

  It is NOT a query-count reduction on this path: `find_applicable_budgets/2` yields
  at most one budget per scope_type (composite unique index), so the batched query
  count equals the number of applicable budgets the old loop issued. TC-33.5.2 below
  therefore guards the query FORM (one grouped GROUP BY aggregate per distinct
  scope_type, never the per-budget single-row select), not a reduction.

  - AC-33.5.1: spend obtained via the batched grouped query; value identical to the
    per-budget computation.
  - AC-33.5.2: threshold-crossing side effects (WebhookEvent + Oban + audit + budget
    flag CAS) are byte-for-byte unchanged.
  - AC-33.5.3: tenant isolation — batched spend scoped to the report's tenant only.
  - AC-33.5.4: find_applicable_budgets' own queries are out of scope.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.PlanAssertions
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Budget
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.WebhookEvent

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

  defp threshold_crossed_entries(tenant_id, budget_id) do
    AuditLog
    |> where(
      [a],
      a.tenant_id == ^tenant_id and a.entity_type == "token_budget" and
        a.entity_id == ^budget_id and a.action == "threshold_crossed"
    )
    |> AdminRepo.all()
  end

  defp report_attrs(story, agent, project, cost) do
    %{
      story_id: story.id,
      agent_id: agent.id,
      project_id: project.id,
      input_tokens: 1000,
      output_tokens: 500,
      model_name: "claude-opus-4",
      cost_millicents: cost
    }
  end

  # SQL for the batched spend aggregate: a GROUP BY over the countable_reports
  # base with a sum of cost_millicents. Excludes the (unrelated) rollup/summary
  # aggregates by keying on the reports table + grouping.
  defp spend_aggregate_query?(sql) do
    String.contains?(sql, "sum") and String.contains?(sql, "cost_millicents") and
      String.contains?(sql, "GROUP BY")
  end

  defp single_row_spend_query?(sql) do
    String.contains?(sql, "sum") and String.contains?(sql, "cost_millicents") and
      not String.contains?(sql, "GROUP BY")
  end

  # --- TC-33.5.2: spend computed via the batched GROUP BY form, one grouped
  #     aggregate per distinct scope_type — NOT the per-budget single-row
  #     get_scope_spend loop (anti-regression on query FORM, not a reduction) ---

  describe "batched spend queries (TC-33.5.2, AC-33.5.1)" do
    test "spend for a report applying to story+epic+project budgets uses batched GROUP BY, not per-budget single-row selects" do
      %{tenant: tenant, story: story, epic: epic, project: project, agent: agent} =
        setup_context()

      # A budget at each of the three scope levels — the report applies to all three.
      for {scope_type, scope_id} <- [
            {:story, story.id},
            {:epic, epic.id},
            {:project, project.id}
          ] do
        {:ok, _} =
          TokenUsage.create_budget(tenant.id, %{
            scope_type: scope_type,
            scope_id: scope_id,
            budget_millicents: 1_000_000,
            alert_threshold_pct: 80
          })
      end

      captured =
        PlanAssertions.capture_repo_queries(fn ->
          {:ok, _report} =
            TokenUsage.create_report(
              tenant.id,
              report_attrs(story, agent, project, 5_000)
            )
        end)

      sqls = Enum.map(captured, fn {sql, _} -> sql end)

      spend_aggregate_sqls = Enum.filter(sqls, &spend_aggregate_query?/1)
      single_row_sqls = Enum.filter(sqls, &single_row_spend_query?/1)

      # This guards the query FORM, not a query-count reduction: on the threshold
      # path find_applicable_budgets/2 yields at most one budget per scope_type, so
      # the batched path issues EXACTLY one grouped GROUP BY aggregate per distinct
      # scope_type (here 3: story/epic/project) — the same count the old per-budget
      # loop issued. Pinning == 3 locks in "one grouped aggregate per distinct
      # scope_type"; single_row_sqls == [] locks in that we never revert to the
      # divergent per-budget get_scope_spend single-row select loop.
      assert length(spend_aggregate_sqls) == 3,
             "expected exactly one grouped GROUP BY spend query per distinct scope_type (3), got: #{inspect(spend_aggregate_sqls)}"

      assert single_row_sqls == [],
             "expected NO per-budget single-row get_scope_spend selects, got: #{inspect(single_row_sqls)}"
    end
  end

  # --- TC-33.5.1: threshold crossing fires identically via batched spend ---

  describe "threshold crossing via batched spend (TC-33.5.1, AC-33.5.2)" do
    test "warning + exceeded fire with the same side effects; batched spend equals per-budget spend" do
      %{tenant: tenant, story: story, project: project, agent: agent} = setup_context()

      _warn_hook = create_webhook_for_events(tenant.id, ["token.budget_warning"])
      _exceed_hook = create_webhook_for_events(tenant.id, ["token.budget_exceeded"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 5_000,
          alert_threshold_pct: 80
        })

      # 6,000 / 5,000 = 120% — crosses BOTH warning (80%) and exceeded (100%) at once.
      {:ok, report} =
        TokenUsage.create_report(tenant.id, report_attrs(story, agent, project, 6_000))

      warning_events = find_webhook_events(tenant.id, "token.budget_warning")
      exceeded_events = find_webhook_events(tenant.id, "token.budget_exceeded")

      assert [warn_event] = warning_events
      assert [exceed_event] = exceeded_events

      # Batched spend used in the payload equals the direct per-budget computation.
      per_budget_spend = TokenUsage.get_scope_spend(tenant.id, :story, story.id)
      assert per_budget_spend == 6_000
      assert warn_event.payload["current_spend_millicents"] == 6_000
      assert exceed_event.payload["current_spend_millicents"] == 6_000
      assert exceed_event.payload["overage_millicents"] == 1_000
      assert exceed_event.payload["triggering_report_id"] == report.id

      # Budget CAS flags flipped exactly once.
      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == true
      assert reloaded.exceeded_fired == true

      # Audit threshold_crossed entries written for both the warning and exceeded
      # crossings (a distinct, durable side effect independent of webhook delivery).
      crossing_types =
        threshold_crossed_entries(tenant.id, budget.id)
        |> Enum.map(& &1.metadata["threshold_type"])
        |> Enum.sort()

      assert crossing_types == ["exceeded", "warning"]
    end
  end

  # --- TC-33.5.3: no threshold crossing when under budget ---

  describe "no crossing when under budget (TC-33.5.3)" do
    test "no threshold event fires; batched spend matches per-budget spend" do
      %{tenant: tenant, story: story, project: project, agent: agent} = setup_context()

      _warn_hook = create_webhook_for_events(tenant.id, ["token.budget_warning"])
      _exceed_hook = create_webhook_for_events(tenant.id, ["token.budget_exceeded"])

      {:ok, budget} =
        TokenUsage.create_budget(tenant.id, %{
          scope_type: :story,
          scope_id: story.id,
          budget_millicents: 100_000,
          alert_threshold_pct: 80
        })

      # 5,000 / 100,000 = 5% — well under both thresholds.
      {:ok, _report} =
        TokenUsage.create_report(tenant.id, report_attrs(story, agent, project, 5_000))

      assert find_webhook_events(tenant.id, "token.budget_warning") == []
      assert find_webhook_events(tenant.id, "token.budget_exceeded") == []

      reloaded = AdminRepo.get!(Budget, budget.id)
      assert reloaded.warning_fired == false
      assert reloaded.exceeded_fired == false

      assert TokenUsage.get_scope_spend(tenant.id, :story, story.id) == 5_000
    end
  end

  # --- TC-33.5.4: tenant isolation of spend ---

  describe "tenant isolation of batched spend (TC-33.5.4, AC-33.5.3)" do
    test "only the report's tenant spend is aggregated; other tenant never included" do
      ctx_a = setup_context()
      ctx_b = setup_context()

      _hook_a = create_webhook_for_events(ctx_a.tenant.id, ["token.budget_warning"])

      {:ok, budget_a} =
        TokenUsage.create_budget(ctx_a.tenant.id, %{
          scope_type: :story,
          scope_id: ctx_a.story.id,
          budget_millicents: 10_000,
          alert_threshold_pct: 80
        })

      # Tenant B has spend on ITS OWN story — must never leak into tenant A's total.
      {:ok, _b_report} =
        TokenUsage.create_report(
          ctx_b.tenant.id,
          report_attrs(ctx_b.story, ctx_b.agent, ctx_b.project, 9_000)
        )

      # Tenant A report pushes A's story to 85% (8,500/10,000). If B's 9,000 leaked,
      # utilization would look different and the batched sum would exceed 8,500.
      {:ok, _a_report} =
        TokenUsage.create_report(
          ctx_a.tenant.id,
          report_attrs(ctx_a.story, ctx_a.agent, ctx_a.project, 8_500)
        )

      events = find_webhook_events(ctx_a.tenant.id, "token.budget_warning")
      assert [event] = events
      assert event.payload["current_spend_millicents"] == 8_500

      # Direct per-budget spend is also tenant-scoped and matches.
      assert TokenUsage.get_scope_spend(ctx_a.tenant.id, :story, ctx_a.story.id) == 8_500

      reloaded_a = AdminRepo.get!(Budget, budget_a.id)
      assert reloaded_a.warning_fired == true
    end
  end
end
