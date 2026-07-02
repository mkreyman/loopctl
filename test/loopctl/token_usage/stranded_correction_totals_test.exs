defmodule Loopctl.TokenUsage.StrandedCorrectionTotalsTest do
  @moduledoc """
  Cross-module regression for tokens-04: after an ORIGINAL report is
  soft-deleted, its surviving negative correction must NOT be stranded into any
  total-computing query. Every analytics endpoint, the cost-summary rollup, and
  the cost-anomaly per-story cost must exclude the stranded correction so no
  total goes negative (or skews low).

  Guards against regressions where a query filters only `is_nil(deleted_at)`
  without routing through `Report.exclude_stranded_corrections/1`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Analytics
  alias Loopctl.TokenUsage.CostAnomaly
  alias Loopctl.TokenUsage.CostSummary
  alias Loopctl.TokenUsage.DefaultRollup
  alias Loopctl.Workers.CostAnomalyWorker

  setup :verify_on_exit!

  defp setup_stranded do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})

    {:ok, original} =
      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500
      })

    {:ok, _correction} =
      TokenUsage.create_correction(tenant.id, original.id, %{
        input_tokens: -100,
        output_tokens: -50,
        cost_millicents: -250
      })

    # Remove the positive original, leaving only the negative correction.
    {:ok, _} = TokenUsage.delete_report(tenant.id, original.id)

    %{tenant: tenant, project: project, epic: epic, agent: agent, story: story}
  end

  test "story totals never go negative after the original is soft-deleted" do
    %{tenant: tenant, story: story} = setup_stranded()

    {:ok, totals} = TokenUsage.get_story_totals(tenant.id, story.id)
    assert totals.total_cost_millicents == 0
    assert totals.total_input_tokens == 0
    assert totals.total_output_tokens == 0
  end

  test "project_metrics excludes the stranded correction" do
    %{tenant: tenant, project: project} = setup_stranded()

    {:ok, m} = Analytics.project_metrics(tenant.id, project.id)
    assert m.total_cost_millicents == 0
    assert m.total_input_tokens == 0
    assert m.total_output_tokens == 0
    assert m.total_cost_millicents >= 0
  end

  test "epic_metrics excludes the stranded correction" do
    %{tenant: tenant, epic: epic} = setup_stranded()

    {:ok, %{data: data}} = Analytics.epic_metrics(tenant.id)
    entry = Enum.find(data, &(&1.epic_id == epic.id))

    assert entry.total_cost_millicents == 0
    assert Enum.all?(data, &(&1.total_cost_millicents >= 0))
  end

  test "agent_metrics never returns a negative agent total" do
    %{tenant: tenant, agent: agent} = setup_stranded()

    {:ok, %{data: data}} = Analytics.agent_metrics(tenant.id)

    assert Enum.all?(data, &(&1.total_cost_millicents >= 0))

    case Enum.find(data, &(&1.agent_id == agent.id)) do
      nil -> :ok
      entry -> assert entry.total_cost_millicents == 0
    end
  end

  test "model_metrics never returns a negative model total" do
    %{tenant: tenant} = setup_stranded()

    {:ok, %{data: data}} = Analytics.model_metrics(tenant.id)
    assert Enum.all?(data, &(&1.total_cost_millicents >= 0))
  end

  test "trend_metrics never returns a negative period total" do
    %{tenant: tenant} = setup_stranded()

    {:ok, %{data: data}} = Analytics.trend_metrics(tenant.id)
    assert Enum.all?(data, &(&1.total_cost_millicents >= 0))
  end

  test "model_mix matrix and comparative never go negative" do
    %{tenant: tenant} = setup_stranded()

    {:ok, %{matrix: matrix, comparative: comparative}} = Analytics.model_mix(tenant.id)

    assert Enum.all?(matrix, &(&1.total_cost_millicents >= 0))

    for group <- [comparative.mixed_model, comparative.single_model] do
      case group.avg_cost_per_story_millicents do
        nil -> :ok
        avg -> assert avg >= 0
      end
    end
  end

  test "agent_model_profile excludes the stranded correction" do
    %{tenant: tenant, agent: agent} = setup_stranded()

    {:ok, profile} = Analytics.agent_model_profile(tenant.id, agent.id)
    assert profile.total_cost_millicents == 0
    assert Enum.all?(profile.usage, &(&1.total_cost_millicents >= 0))
  end

  test "cost-summary rollup never produces a negative scope total" do
    %{tenant: tenant, epic: epic, project: project, agent: agent} = setup_stranded()

    today = Date.utc_today()
    {:ok, rows} = DefaultRollup.aggregate(tenant.id, today, today)

    assert Enum.all?(rows, &(&1.total_cost_millicents >= 0))

    for {scope_type, scope_id} <- [
          {:epic, epic.id},
          {:project, project.id},
          {:agent, agent.id}
        ] do
      case Enum.find(rows, &(&1.scope_type == scope_type and &1.scope_id == scope_id)) do
        nil -> :ok
        row -> assert row.total_cost_millicents == 0
      end
    end
  end

  test "cost-anomaly per-story cost excludes the stranded correction (no false anomaly)" do
    %{tenant: tenant, epic: epic, story: story} = setup_stranded()

    today = Date.utc_today()

    # Epic average so the worker has a reference. A stranded per-story cost of
    # -250 would be far below 0.1x this average and (pre-fix) flag a false
    # `suspiciously_low` anomaly. With the fix the story has no countable
    # reports, so it never enters the per-story cost scan.
    %CostSummary{tenant_id: tenant.id}
    |> CostSummary.changeset(%{
      scope_type: :epic,
      scope_id: epic.id,
      period_start: today,
      period_end: today,
      total_cost_millicents: 10_000,
      story_count: 2,
      avg_cost_per_story_millicents: 5_000
    })
    |> AdminRepo.insert!()

    job_args = %{
      "period_start" => Date.to_iso8601(today),
      "period_end" => Date.to_iso8601(today)
    }

    assert :ok = CostAnomalyWorker.perform(%Oban.Job{args: job_args, id: 1})

    anomalies =
      CostAnomaly
      |> where([a], a.tenant_id == ^tenant.id and a.story_id == ^story.id)
      |> AdminRepo.all()

    assert anomalies == []
  end

  test "a correction whose original is LIVE still counts across analytics" do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    story = fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})

    {:ok, original} =
      TokenUsage.create_report(tenant.id, %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500
      })

    {:ok, _} =
      TokenUsage.create_correction(tenant.id, original.id, %{
        input_tokens: -100,
        output_tokens: -50,
        cost_millicents: -250
      })

    # Original live -> both the original and its correction count: 2500 - 250.
    {:ok, m} = Analytics.project_metrics(tenant.id, project.id)
    assert m.total_cost_millicents == 2250
  end
end
