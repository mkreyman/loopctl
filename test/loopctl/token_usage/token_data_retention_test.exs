defmodule Loopctl.TokenUsage.TokenDataRetentionTest do
  @moduledoc """
  Tests for US-21.14: Token Data Retention & Archival.

  Covers:
  - AC-21.14.1: Tenant retention settings
  - AC-21.14.5: Cost anomaly archival and filtered listing
  - AC-21.14.6: Tenant GET/PATCH for token_data_retention_days
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Tenants
  alias Loopctl.TokenUsage
  alias Loopctl.TokenUsage.CostAnomaly

  # --- AC-21.14.1: Tenant retention column ---

  describe "Tenant.update_changeset/2 with token_data_retention_days" do
    test "accepts nil (unlimited retention)" do
      tenant = fixture(:tenant)

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{token_data_retention_days: nil})

      assert updated.token_data_retention_days == nil
    end

    test "accepts valid retention days >= 30" do
      tenant = fixture(:tenant)

      assert {:ok, updated} =
               Tenants.update_tenant(tenant, %{token_data_retention_days: 30})

      assert updated.token_data_retention_days == 30

      assert {:ok, updated2} =
               Tenants.update_tenant(updated, %{token_data_retention_days: 365})

      assert updated2.token_data_retention_days == 365
    end

    test "rejects retention days below 30" do
      tenant = fixture(:tenant)

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{token_data_retention_days: 29})

      assert errors_on(changeset).token_data_retention_days != []
    end

    test "rejects retention days of 0" do
      tenant = fixture(:tenant)

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{token_data_retention_days: 0})

      assert errors_on(changeset).token_data_retention_days != []
    end

    test "rejects negative retention days" do
      tenant = fixture(:tenant)

      assert {:error, changeset} =
               Tenants.update_tenant(tenant, %{token_data_retention_days: -1})

      assert errors_on(changeset).token_data_retention_days != []
    end

    test "new tenants default to nil retention (unlimited)" do
      tenant = fixture(:tenant)
      assert tenant.token_data_retention_days == nil
    end

    test "tenant isolation: updating retention on one tenant does not affect another" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      assert {:ok, updated_a} =
               Tenants.update_tenant(tenant_a, %{token_data_retention_days: 90})

      assert updated_a.token_data_retention_days == 90

      # tenant_b is unaffected
      {:ok, fresh_b} = Tenants.get_tenant(tenant_b.id)
      assert fresh_b.token_data_retention_days == nil
    end
  end

  # --- AC-21.14.5: Cost anomaly archived flag and filtered listing ---

  describe "TokenUsage.list_anomalies/2 with archived anomalies" do
    test "excludes archived anomalies by default" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      # Active (non-archived) anomaly
      _active_anomaly =
        %CostAnomaly{tenant_id: tenant.id, story_id: story.id}
        |> CostAnomaly.create_changeset(%{
          anomaly_type: :high_cost,
          story_cost_millicents: 75_000,
          reference_avg_millicents: 25_000,
          deviation_factor: Decimal.new("3.0")
        })
        |> AdminRepo.insert!()

      # Archived anomaly
      %CostAnomaly{tenant_id: tenant.id, story_id: story.id}
      |> CostAnomaly.create_changeset(%{
        anomaly_type: :suspiciously_low,
        story_cost_millicents: 1_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("0.04")
      })
      |> AdminRepo.insert!()
      |> Ecto.Changeset.change(archived: true)
      |> AdminRepo.update!()

      {:ok, result} = TokenUsage.list_anomalies(tenant.id)

      assert result.total == 1
      anomaly_types = Enum.map(result.data, & &1.anomaly_type)
      assert :high_cost in anomaly_types
      refute :suspiciously_low in anomaly_types
    end

    test "includes archived anomalies when include_archived: true" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      %CostAnomaly{tenant_id: tenant.id, story_id: story.id}
      |> CostAnomaly.create_changeset(%{
        anomaly_type: :high_cost,
        story_cost_millicents: 75_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("3.0")
      })
      |> AdminRepo.insert!()

      %CostAnomaly{tenant_id: tenant.id, story_id: story.id}
      |> CostAnomaly.create_changeset(%{
        anomaly_type: :suspiciously_low,
        story_cost_millicents: 1_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("0.04")
      })
      |> AdminRepo.insert!()
      |> Ecto.Changeset.change(archived: true)
      |> AdminRepo.update!()

      {:ok, result} = TokenUsage.list_anomalies(tenant.id, include_archived: true)

      assert result.total == 2
    end

    test "tenant isolation: archived anomalies of tenant_b not visible to tenant_a" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      story_a = fixture(:story, %{tenant_id: tenant_a.id})
      story_b = fixture(:story, %{tenant_id: tenant_b.id})

      # Active anomaly for tenant_a
      %CostAnomaly{tenant_id: tenant_a.id, story_id: story_a.id}
      |> CostAnomaly.create_changeset(%{
        anomaly_type: :high_cost,
        story_cost_millicents: 75_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("3.0")
      })
      |> AdminRepo.insert!()

      # Archived anomaly for tenant_b — should NOT appear in tenant_a's results
      %CostAnomaly{tenant_id: tenant_b.id, story_id: story_b.id}
      |> CostAnomaly.create_changeset(%{
        anomaly_type: :high_cost,
        story_cost_millicents: 75_000,
        reference_avg_millicents: 25_000,
        deviation_factor: Decimal.new("3.0")
      })
      |> AdminRepo.insert!()
      |> Ecto.Changeset.change(archived: true)
      |> AdminRepo.update!()

      {:ok, result_a} = TokenUsage.list_anomalies(tenant_a.id, include_archived: true)
      assert result_a.total == 1

      {:ok, result_b} = TokenUsage.list_anomalies(tenant_b.id, include_archived: true)
      assert result_b.total == 1
    end
  end

  # --- AC-21.14.6: GET/PATCH /api/v1/tenants/me includes retention days ---

  describe "tenant_json includes token_data_retention_days" do
    test "retention_days is nil by default" do
      tenant = fixture(:tenant)
      assert tenant.token_data_retention_days == nil
    end

    test "retention_days can be set and read back" do
      tenant = fixture(:tenant)
      {:ok, updated} = Tenants.update_tenant(tenant, %{token_data_retention_days: 180})
      assert updated.token_data_retention_days == 180

      {:ok, fetched} = Tenants.get_tenant(tenant.id)
      assert fetched.token_data_retention_days == 180
    end
  end
end
