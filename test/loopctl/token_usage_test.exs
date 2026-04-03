defmodule Loopctl.TokenUsageTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.Report

  setup :verify_on_exit!

  defp setup_story do
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

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      story: story
    }
  end

  # --- create_report/3 ---

  describe "create_report/3" do
    test "creates a token usage report with valid attributes" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500,
        phase: "implementing"
      }

      assert {:ok, %Report{} = report} = TokenUsage.create_report(tenant.id, attrs)

      assert report.tenant_id == tenant.id
      assert report.story_id == story.id
      assert report.agent_id == agent.id
      assert report.project_id == project.id
      assert report.input_tokens == 1000
      assert report.output_tokens == 500
      assert report.model_name == "claude-opus-4"
      assert report.cost_millicents == 2500
      assert report.phase == "implementing"
    end

    test "total_tokens is generated from input + output" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 3000,
        output_tokens: 1500,
        model_name: "claude-sonnet-4",
        cost_millicents: 1200
      }

      {:ok, report} = TokenUsage.create_report(tenant.id, attrs)

      # Re-fetch to get generated column value
      report = Loopctl.AdminRepo.get!(Report, report.id)
      assert report.total_tokens == 4500
    end

    test "defaults phase to 'other' when not specified" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-sonnet-4",
        cost_millicents: 100
      }

      {:ok, report} = TokenUsage.create_report(tenant.id, attrs)
      assert report.phase == "other"
    end

    test "accepts optional session_id and metadata" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "gpt-4o",
        cost_millicents: 500,
        session_id: "session-abc-123",
        metadata: %{"tool_calls" => 5}
      }

      {:ok, report} = TokenUsage.create_report(tenant.id, attrs)
      assert report.session_id == "session-abc-123"
      assert report.metadata == %{"tool_calls" => 5}
    end

    test "returns error when input_tokens is negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: -1,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 100
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).input_tokens != []
    end

    test "returns error when output_tokens is negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: -5,
        model_name: "claude-opus-4",
        cost_millicents: 100
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).output_tokens != []
    end

    test "returns error when cost_millicents is negative" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: -1
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).cost_millicents != []
    end

    test "returns error when model_name is empty" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "",
        cost_millicents: 100
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).model_name != []
    end

    test "returns error when model_name is missing" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        cost_millicents: 100
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).model_name != []
    end

    test "returns error with invalid phase" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 100,
        output_tokens: 50,
        model_name: "claude-opus-4",
        cost_millicents: 100,
        phase: "invalid_phase"
      }

      assert {:error, changeset} = TokenUsage.create_report(tenant.id, attrs)
      assert errors_on(changeset).phase != []
    end

    test "creates an audit log entry" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        model_name: "claude-opus-4",
        cost_millicents: 2500
      }

      {:ok, report} = TokenUsage.create_report(tenant.id, attrs, actor_id: Ecto.UUID.generate())

      {:ok, result} =
        Loopctl.Audit.list_entries(tenant.id,
          entity_type: "token_usage_report",
          entity_id: report.id,
          action: "created"
        )

      assert length(result.data) == 1
      audit = hd(result.data)
      assert audit.entity_type == "token_usage_report"
      assert audit.action == "created"

      # AC-21.8.1: new_state contains story_id, agent_id, model_name, cost_millicents, total_tokens
      assert audit.new_state["model_name"] == "claude-opus-4"
      assert audit.new_state["total_tokens"] == 1500
      assert audit.new_state["cost_millicents"] == 2500
    end

    test "accepts string keys in attrs" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      attrs = %{
        "story_id" => story.id,
        "agent_id" => agent.id,
        "project_id" => project.id,
        "input_tokens" => 1000,
        "output_tokens" => 500,
        "model_name" => "claude-opus-4",
        "cost_millicents" => 2500
      }

      assert {:ok, %Report{}} = TokenUsage.create_report(tenant.id, attrs)
    end
  end

  # --- list_reports_for_story/3 ---

  describe "list_reports_for_story/3" do
    test "returns reports ordered by inserted_at descending" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      for i <- 1..3 do
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id,
          input_tokens: i * 100
        })
      end

      {:ok, result} = TokenUsage.list_reports_for_story(tenant.id, story.id)

      assert length(result.data) == 3
      assert result.total == 3
      assert result.page == 1

      # Should be in descending order
      tokens = Enum.map(result.data, & &1.input_tokens)
      assert tokens == Enum.sort(tokens, :desc)
    end

    test "paginates results" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      for _i <- 1..5 do
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          story_id: story.id,
          agent_id: agent.id,
          project_id: project.id
        })
      end

      {:ok, result} =
        TokenUsage.list_reports_for_story(tenant.id, story.id, page: 1, page_size: 2)

      assert length(result.data) == 2
      assert result.total == 5
      assert result.page_size == 2

      {:ok, result2} =
        TokenUsage.list_reports_for_story(tenant.id, story.id, page: 2, page_size: 2)

      assert length(result2.data) == 2
    end

    test "returns empty list for story with no reports" do
      %{tenant: tenant, story: story} = setup_story()

      {:ok, result} = TokenUsage.list_reports_for_story(tenant.id, story.id)
      assert result.data == []
      assert result.total == 0
    end
  end

  # --- get_story_totals/2 ---

  describe "get_story_totals/2" do
    test "returns aggregated totals" do
      %{tenant: tenant, story: story, agent: agent, project: project} = setup_story()

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 1000,
        output_tokens: 500,
        cost_millicents: 2500
      })

      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story.id,
        agent_id: agent.id,
        project_id: project.id,
        input_tokens: 2000,
        output_tokens: 1000,
        cost_millicents: 5000
      })

      {:ok, totals} = TokenUsage.get_story_totals(tenant.id, story.id)

      assert totals.total_input_tokens == 3000
      assert totals.total_output_tokens == 1500
      assert totals.total_tokens == 4500
      assert totals.total_cost_millicents == 7500
      assert totals.report_count == 2
    end

    test "returns zeros when no reports exist" do
      %{tenant: tenant, story: story} = setup_story()

      {:ok, totals} = TokenUsage.get_story_totals(tenant.id, story.id)

      assert totals.total_input_tokens == 0
      assert totals.total_output_tokens == 0
      assert totals.total_tokens == 0
      assert totals.total_cost_millicents == 0
      assert totals.report_count == 0
    end
  end

  # --- Tenant isolation ---

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's token usage reports" do
      %{tenant: tenant_a, story: story_a, agent: agent_a, project: project_a} = setup_story()

      fixture(:token_usage_report, %{
        tenant_id: tenant_a.id,
        story_id: story_a.id,
        agent_id: agent_a.id,
        project_id: project_a.id
      })

      tenant_b = fixture(:tenant)

      # Tenant B should see zero reports for the same story_id
      {:ok, result} = TokenUsage.list_reports_for_story(tenant_b.id, story_a.id)
      assert result.data == []
      assert result.total == 0

      {:ok, totals} = TokenUsage.get_story_totals(tenant_b.id, story_a.id)
      assert totals.report_count == 0
    end
  end

  # --- Fixture test ---

  describe "fixture/2" do
    test "creates a token usage report with auto-dependency resolution" do
      report = fixture(:token_usage_report)

      assert report.id != nil
      assert report.tenant_id != nil
      assert report.story_id != nil
      assert report.agent_id != nil
      assert report.project_id != nil
      assert report.input_tokens == 1000
      assert report.output_tokens == 500
      assert report.model_name == "claude-opus-4"
      assert report.cost_millicents == 2500
    end

    test "creates a token usage report with custom attributes" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      report =
        fixture(:token_usage_report, %{
          tenant_id: tenant.id,
          agent_id: agent.id,
          input_tokens: 5000,
          output_tokens: 2000,
          model_name: "gpt-4o",
          cost_millicents: 8000,
          phase: "reviewing"
        })

      assert report.tenant_id == tenant.id
      assert report.agent_id == agent.id
      assert report.input_tokens == 5000
      assert report.output_tokens == 2000
      assert report.model_name == "gpt-4o"
      assert report.cost_millicents == 8000
      assert report.phase == "reviewing"
    end
  end
end
