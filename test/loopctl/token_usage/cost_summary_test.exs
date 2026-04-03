defmodule Loopctl.TokenUsage.CostSummaryTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.TokenUsage.CostSummary

  describe "changeset/2" do
    test "valid changeset with required fields" do
      changeset =
        CostSummary.changeset(%CostSummary{}, %{
          scope_type: :project,
          scope_id: Ecto.UUID.generate(),
          period_start: ~D[2026-04-01],
          period_end: ~D[2026-04-01],
          total_input_tokens: 1000,
          total_output_tokens: 500,
          total_cost_millicents: 2500,
          report_count: 5,
          model_breakdown: %{"claude-opus-4" => %{"other" => %{"input_tokens" => 1000}}}
        })

      assert changeset.valid?
    end

    test "requires scope_type, scope_id, period_start, period_end" do
      changeset = CostSummary.changeset(%CostSummary{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:scope_type]
      assert errors[:scope_id]
      assert errors[:period_start]
      assert errors[:period_end]
    end

    test "validates scope_type enum values" do
      changeset =
        CostSummary.changeset(%CostSummary{}, %{
          scope_type: :invalid,
          scope_id: Ecto.UUID.generate(),
          period_start: ~D[2026-04-01],
          period_end: ~D[2026-04-01]
        })

      refute changeset.valid?
      assert errors_on(changeset)[:scope_type]
    end

    test "accepts all valid scope types" do
      for scope_type <- [:agent, :epic, :project, :story] do
        changeset =
          CostSummary.changeset(%CostSummary{}, %{
            scope_type: scope_type,
            scope_id: Ecto.UUID.generate(),
            period_start: ~D[2026-04-01],
            period_end: ~D[2026-04-01]
          })

        assert changeset.valid?, "Expected #{scope_type} to be valid"
      end
    end

    test "validates non-negative numbers" do
      changeset =
        CostSummary.changeset(%CostSummary{}, %{
          scope_type: :project,
          scope_id: Ecto.UUID.generate(),
          period_start: ~D[2026-04-01],
          period_end: ~D[2026-04-01],
          total_input_tokens: -1,
          total_output_tokens: -1,
          total_cost_millicents: -1,
          report_count: -1
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:total_input_tokens]
      assert errors[:total_output_tokens]
      assert errors[:total_cost_millicents]
      assert errors[:report_count]
    end
  end

  describe "fixture" do
    test "creates a cost summary with defaults" do
      summary = fixture(:cost_summary)

      assert summary.id
      assert summary.tenant_id
      assert summary.scope_type == :project
      assert summary.total_cost_millicents == 25_000
    end

    test "creates a cost summary with overrides" do
      tenant = fixture(:tenant)
      epic = fixture(:epic, %{tenant_id: tenant.id})

      summary =
        fixture(:cost_summary, %{
          tenant_id: tenant.id,
          scope_type: :epic,
          scope_id: epic.id,
          total_cost_millicents: 99_999
        })

      assert summary.scope_type == :epic
      assert summary.scope_id == epic.id
      assert summary.total_cost_millicents == 99_999
    end
  end

  describe "unique constraint" do
    test "enforces unique (tenant_id, scope_type, scope_id, period_start)" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      _first =
        fixture(:cost_summary, %{
          tenant_id: tenant.id,
          scope_type: :project,
          scope_id: project.id,
          period_start: ~D[2026-04-01],
          period_end: ~D[2026-04-01]
        })

      # Second insert with same key should fail
      changeset =
        %CostSummary{tenant_id: tenant.id}
        |> CostSummary.changeset(%{
          scope_type: :project,
          scope_id: project.id,
          period_start: ~D[2026-04-01],
          period_end: ~D[2026-04-01]
        })

      assert {:error, changeset} = AdminRepo.insert(changeset)
      assert errors_on(changeset)[:tenant_id]
    end
  end
end
