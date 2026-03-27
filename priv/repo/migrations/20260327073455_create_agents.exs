defmodule Loopctl.Repo.Migrations.CreateAgents do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :agent_type, :string, null: false
      add :status, :string, null: false, default: "active"
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:tenant_id, :name])
    create index(:agents, [:tenant_id])
    create index(:agents, [:agent_type])
    create index(:agents, [:status])

    enable_rls(:agents)
  end
end
