defmodule Loopctl.TokenUsage.CostAnomalyTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.TokenUsage

  defp setup_tenant_with_anomalies do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    story1 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id,
        assigned_agent_id: agent.id
      })

    story2 =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        project_id: project.id
      })

    anomaly1 =
      fixture(:cost_anomaly, %{
        tenant_id: tenant.id,
        story_id: story1.id,
        anomaly_type: :high_cost,
        story_cost_millicents: 100_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("4.0")
      })

    anomaly2 =
      fixture(:cost_anomaly, %{
        tenant_id: tenant.id,
        story_id: story2.id,
        anomaly_type: :suspiciously_low,
        story_cost_millicents: 100,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("0.004")
      })

    %{
      tenant: tenant,
      project: project,
      epic: epic,
      agent: agent,
      story1: story1,
      story2: story2,
      anomaly1: anomaly1,
      anomaly2: anomaly2
    }
  end

  describe "list_anomalies/2" do
    test "returns unresolved anomalies for a tenant" do
      ctx = setup_tenant_with_anomalies()
      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id)

      assert result.total == 2
      assert length(result.data) == 2

      # Check that story title is included
      anomaly_data = Enum.find(result.data, &(&1.story_id == ctx.story1.id))
      assert anomaly_data.story_title != nil
      assert anomaly_data.anomaly_type == :high_cost
    end

    test "includes agent name when story has an assigned agent" do
      ctx = setup_tenant_with_anomalies()
      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id)

      anomaly_with_agent = Enum.find(result.data, &(&1.story_id == ctx.story1.id))
      assert anomaly_with_agent.agent_name == ctx.agent.name
    end

    test "filters by anomaly_type" do
      ctx = setup_tenant_with_anomalies()

      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id, anomaly_type: "high_cost")
      assert result.total == 1
      assert hd(result.data).anomaly_type == :high_cost
    end

    test "filters by project_id" do
      ctx = setup_tenant_with_anomalies()

      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id, project_id: ctx.project.id)
      assert result.total == 2

      # Different project should return 0
      other_project = fixture(:project, %{tenant_id: ctx.tenant.id})
      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id, project_id: other_project.id)
      assert result.total == 0
    end

    test "excludes resolved anomalies by default" do
      ctx = setup_tenant_with_anomalies()

      # Resolve one anomaly
      {:ok, _} = TokenUsage.resolve_anomaly(ctx.tenant.id, ctx.anomaly1.id)

      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id)
      assert result.total == 1
      assert hd(result.data).story_id == ctx.story2.id
    end

    test "supports pagination" do
      ctx = setup_tenant_with_anomalies()

      {:ok, result} = TokenUsage.list_anomalies(ctx.tenant.id, page: 1, page_size: 1)
      assert result.total == 2
      assert result.page == 1
      assert result.page_size == 1
      assert length(result.data) == 1
    end

    test "tenant isolation - tenant A cannot see tenant B's anomalies" do
      ctx = setup_tenant_with_anomalies()

      tenant_b = fixture(:tenant)
      {:ok, result} = TokenUsage.list_anomalies(tenant_b.id)
      assert result.total == 0
      assert result.data == []

      # Verify tenant A can see its own
      {:ok, result_a} = TokenUsage.list_anomalies(ctx.tenant.id)
      assert result_a.total == 2
    end
  end

  describe "get_anomaly/2" do
    test "returns anomaly by ID and tenant" do
      ctx = setup_tenant_with_anomalies()

      {:ok, anomaly} = TokenUsage.get_anomaly(ctx.tenant.id, ctx.anomaly1.id)
      assert anomaly.id == ctx.anomaly1.id
    end

    test "returns not_found for wrong tenant" do
      ctx = setup_tenant_with_anomalies()
      tenant_b = fixture(:tenant)

      assert {:error, :not_found} = TokenUsage.get_anomaly(tenant_b.id, ctx.anomaly1.id)
    end

    test "returns not_found for non-existent anomaly" do
      tenant = fixture(:tenant)
      assert {:error, :not_found} = TokenUsage.get_anomaly(tenant.id, Ecto.UUID.generate())
    end
  end

  describe "resolve_anomaly/2" do
    test "marks anomaly as resolved" do
      ctx = setup_tenant_with_anomalies()

      {:ok, anomaly} = TokenUsage.resolve_anomaly(ctx.tenant.id, ctx.anomaly1.id)
      assert anomaly.resolved == true
    end

    test "returns not_found for wrong tenant" do
      ctx = setup_tenant_with_anomalies()
      tenant_b = fixture(:tenant)

      assert {:error, :not_found} = TokenUsage.resolve_anomaly(tenant_b.id, ctx.anomaly1.id)
    end
  end
end
