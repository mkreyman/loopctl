defmodule Loopctl.Repo.Migrations.CreateOrchestratorStates do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:orchestrator_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :state_key, :string, null: false
      add :state_data, :map, null: false, default: %{}
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestrator_states, [:tenant_id, :project_id, :state_key])
    create index(:orchestrator_states, [:tenant_id])
    create index(:orchestrator_states, [:project_id])

    enable_rls(:orchestrator_states)
  end
end
