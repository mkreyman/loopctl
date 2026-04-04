defmodule Loopctl.TokenUsage.ModelMixAnalyticsTest do
  use Loopctl.DataCase, async: true

  import Loopctl.Fixtures

  alias Loopctl.TokenUsage.Analytics

  setup :verify_on_exit!

  # Builds a test dataset with two agents using different model combinations.
  # agent1 (model blender): uses both claude-opus-4 and claude-sonnet-4
  # agent2 (single model): uses only claude-sonnet-4
  defp setup_model_mix_data do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    agent1 = fixture(:agent, %{tenant_id: tenant.id, name: "agent-blender"})
    agent2 = fixture(:agent, %{tenant_id: tenant.id, name: "agent-single"})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent1.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :rejected,
        assigned_agent_id: agent2.id
      })

    story3 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        verified_status: :verified,
        assigned_agent_id: agent1.id
      })

    # agent1 implementing with opus
    _r1 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-opus-4",
        input_tokens: 2000,
        output_tokens: 1000,
        cost_millicents: 6000,
        phase: "implementing"
      })

    # agent1 reviewing with sonnet (makes agent1 a blender)
    _r2 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story3.id,
        agent_id: agent1.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 1000,
        output_tokens: 500,
        cost_millicents: 2000,
        phase: "reviewing"
      })

    # agent2 implementing with sonnet only
    _r3 =
      fixture(:token_usage_report, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        agent_id: agent2.id,
        project_id: project.id,
        model_name: "claude-sonnet-4",
        input_tokens: 1500,
        output_tokens: 700,
        cost_millicents: 3000,
        phase: "implementing"
      })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent1: agent1,
      agent2: agent2,
      story1: story1,
      story2: story2,
      story3: story3
    }
  end

  # ---------------------------------------------------------------------------
  # model_mix/2
  # ---------------------------------------------------------------------------

  describe "model_mix/2" do
    test "returns matrix and comparative" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id)

      assert is_list(result.matrix)
      assert is_map(result.comparative)
    end

    test "matrix contains (model_name, phase) pairs" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id)

      matrix = result.matrix

      # We have: opus/implementing, sonnet/reviewing, sonnet/implementing
      assert length(matrix) == 3

      opus_impl =
        Enum.find(matrix, &(&1.model_name == "claude-opus-4" and &1.phase == "implementing"))

      assert opus_impl != nil
      assert opus_impl.total_cost_millicents == 6000
      assert opus_impl.total_tokens == 3000
      assert opus_impl.stories_count == 1
    end

    test "matrix includes verification outcomes" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id)

      # opus/implementing: story1 is verified
      opus_impl =
        Enum.find(
          result.matrix,
          &(&1.model_name == "claude-opus-4" and &1.phase == "implementing")
        )

      assert opus_impl.verified_count == 1
      assert opus_impl.rejected_count == 0
      assert opus_impl.verification_rate_pct == 100

      # sonnet/implementing: story2 is rejected
      sonnet_impl =
        Enum.find(
          result.matrix,
          &(&1.model_name == "claude-sonnet-4" and &1.phase == "implementing")
        )

      assert sonnet_impl.rejected_count == 1
      assert sonnet_impl.verified_count == 0
    end

    test "comparative view includes mixed_model and single_model groups" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id)

      comp = result.comparative
      assert Map.has_key?(comp, :mixed_model)
      assert Map.has_key?(comp, :single_model)

      # agent1 uses 2 models → mixed_model count = 1
      assert comp.mixed_model.agent_count == 1
      # agent2 uses 1 model → single_model count = 1
      assert comp.single_model.agent_count == 1
    end

    test "comparative groups include avg_cost_per_story and avg_verification_rate" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id)

      comp = result.comparative
      assert Map.has_key?(comp.mixed_model, :avg_cost_per_story_millicents)
      assert Map.has_key?(comp.mixed_model, :avg_verification_rate_pct)
      assert Map.has_key?(comp.single_model, :avg_cost_per_story_millicents)
      assert Map.has_key?(comp.single_model, :avg_verification_rate_pct)
    end

    test "filters by project_id" do
      ctx = setup_model_mix_data()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} = Analytics.model_mix(ctx.tenant.id, project_id: other_project.id)

      assert result.matrix == []
    end

    test "filters by agent_id" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.model_mix(ctx.tenant.id, agent_id: ctx.agent2.id)

      # Only agent2's reports: sonnet/implementing
      assert length(result.matrix) == 1
      entry = hd(result.matrix)
      assert entry.model_name == "claude-sonnet-4"
      assert entry.phase == "implementing"
    end

    test "filters by date range" do
      ctx = setup_model_mix_data()

      {:ok, result} =
        Analytics.model_mix(ctx.tenant.id,
          since: Date.add(Date.utc_today(), 1)
        )

      assert result.matrix == []
    end

    test "returns empty matrix for tenant with no data" do
      tenant = fixture(:tenant)

      {:ok, result} = Analytics.model_mix(tenant.id)

      assert result.matrix == []
      assert result.comparative.mixed_model.agent_count == 0
      assert result.comparative.single_model.agent_count == 0
    end

    test "tenant isolation" do
      ctx = setup_model_mix_data()
      other_tenant = fixture(:tenant)

      {:ok, result} = Analytics.model_mix(other_tenant.id)

      assert result.matrix == []

      # Own tenant still has data
      {:ok, own_result} = Analytics.model_mix(ctx.tenant.id)
      assert own_result.matrix != []
    end
  end

  # ---------------------------------------------------------------------------
  # agent_model_profile/3
  # ---------------------------------------------------------------------------

  describe "agent_model_profile/3" do
    test "returns profile for model-blender agent" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id)

      assert result.agent_id == ctx.agent1.id
      assert result.agent_name == "agent-blender"
      assert result.model_count == 2
      assert result.is_model_blender == true
      assert "claude-opus-4" in result.models_used
      assert "claude-sonnet-4" in result.models_used
    end

    test "returns profile for single-model agent" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.agent_model_profile(ctx.tenant.id, ctx.agent2.id)

      assert result.agent_id == ctx.agent2.id
      assert result.agent_name == "agent-single"
      assert result.model_count == 1
      assert result.is_model_blender == false
      assert result.models_used == ["claude-sonnet-4"]
    end

    test "includes usage breakdown per (model, phase)" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id)

      usage = result.usage
      assert is_list(usage)
      assert length(usage) == 2

      opus_entry =
        Enum.find(usage, &(&1.model_name == "claude-opus-4" and &1.phase == "implementing"))

      assert opus_entry != nil
      assert opus_entry.total_cost_millicents == 6000
      assert opus_entry.total_input_tokens == 2000
      assert opus_entry.total_output_tokens == 1000
    end

    test "includes verification outcomes in usage" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id)

      opus_entry =
        Enum.find(
          result.usage,
          &(&1.model_name == "claude-opus-4" and &1.phase == "implementing")
        )

      assert opus_entry.verified_count == 1
      assert opus_entry.rejected_count == 0
      assert opus_entry.verification_rate_pct == 100
    end

    test "includes cost_share_pct in usage entries" do
      ctx = setup_model_mix_data()

      {:ok, result} = Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id)

      # agent1 total cost: 6000 (opus/implementing) + 2000 (sonnet/reviewing) = 8000
      assert result.total_cost_millicents == 8000

      opus_entry = Enum.find(result.usage, &(&1.model_name == "claude-opus-4"))
      # 6000 / 8000 * 100 = 75%
      assert opus_entry.cost_share_pct == 75

      sonnet_entry = Enum.find(result.usage, &(&1.model_name == "claude-sonnet-4"))
      # 2000 / 8000 * 100 = 25%
      assert sonnet_entry.cost_share_pct == 25
    end

    test "filters by project_id" do
      ctx = setup_model_mix_data()
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})

      {:ok, result} =
        Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id, project_id: other_project.id)

      assert result.usage == []
      assert result.model_count == 0
      assert result.is_model_blender == false
      assert result.total_cost_millicents == 0
    end

    test "filters by date range" do
      ctx = setup_model_mix_data()

      {:ok, result} =
        Analytics.agent_model_profile(ctx.tenant.id, ctx.agent1.id,
          since: Date.add(Date.utc_today(), 1)
        )

      assert result.usage == []
      assert result.model_count == 0
    end

    test "returns not_found for unknown agent" do
      tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Analytics.agent_model_profile(tenant.id, Ecto.UUID.generate())
    end

    test "tenant isolation - agent in other tenant returns not_found" do
      ctx = setup_model_mix_data()
      other_tenant = fixture(:tenant)

      assert {:error, :not_found} =
               Analytics.agent_model_profile(other_tenant.id, ctx.agent1.id)
    end
  end
end
