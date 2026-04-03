defmodule Loopctl.Repo.Migrations.CreateCostSummariesAndAnomalies do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    # --- cost_summaries ---

    create table(:cost_summaries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :scope_type, :string, null: false
      add :scope_id, :binary_id, null: false

      add :period_start, :date, null: false
      add :period_end, :date, null: false

      add :total_input_tokens, :bigint, default: 0
      add :total_output_tokens, :bigint, default: 0
      add :total_cost_millicents, :bigint, default: 0
      add :report_count, :integer, default: 0
      add :model_breakdown, :map, default: %{}
      add :avg_cost_per_story_millicents, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    # scope_type CHECK constraint: agent, epic, project, story
    execute(
      "ALTER TABLE cost_summaries ADD CONSTRAINT cost_summaries_scope_type_check CHECK (scope_type IN ('agent', 'epic', 'project', 'story'))",
      "ALTER TABLE cost_summaries DROP CONSTRAINT cost_summaries_scope_type_check"
    )

    # Composite unique index for idempotent upsert (AC-21.3.10)
    create unique_index(:cost_summaries, [:tenant_id, :scope_type, :scope_id, :period_start],
             name: :cost_summaries_tenant_scope_period_idx
           )

    # Lookup indexes
    create index(:cost_summaries, [:tenant_id])
    create index(:cost_summaries, [:tenant_id, :scope_type])

    enable_rls(:cost_summaries)

    # --- cost_anomalies ---

    create table(:cost_anomalies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :anomaly_type, :string, null: false
      add :story_cost_millicents, :bigint, null: false
      add :reference_avg_millicents, :bigint, null: false
      add :deviation_factor, :decimal, null: false
      add :resolved, :boolean, default: false, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # anomaly_type CHECK constraint
    execute(
      "ALTER TABLE cost_anomalies ADD CONSTRAINT cost_anomalies_anomaly_type_check CHECK (anomaly_type IN ('high_cost', 'suspiciously_low', 'budget_exceeded'))",
      "ALTER TABLE cost_anomalies DROP CONSTRAINT cost_anomalies_anomaly_type_check"
    )

    # Indexes for common queries
    create index(:cost_anomalies, [:tenant_id])
    create index(:cost_anomalies, [:tenant_id, :resolved])
    create index(:cost_anomalies, [:tenant_id, :anomaly_type])
    create index(:cost_anomalies, [:story_id])

    enable_rls(:cost_anomalies)
  end
end
