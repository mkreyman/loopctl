defmodule Loopctl.Repo.Migrations.CreateUiTestRuns do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:ui_test_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :started_by_agent_id,
          references(:agents, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :status, :string, null: false, default: "in_progress"
      add :guide_reference, :string, null: false
      add :findings, {:array, :map}, null: false, default: []
      add :summary, :text, null: true

      add :screenshots_count, :integer, null: false, default: 0
      add :findings_count, :integer, null: false, default: 0
      add :critical_count, :integer, null: false, default: 0
      add :high_count, :integer, null: false, default: 0

      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ui_test_runs, [:tenant_id])
    create index(:ui_test_runs, [:tenant_id, :project_id, :status])

    enable_rls(:ui_test_runs)
  end
end
