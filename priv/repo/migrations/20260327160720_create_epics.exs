defmodule Loopctl.Repo.Migrations.CreateEpics do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:epics, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :title, :string, null: false
      add :description, :text
      add :phase, :string
      add :position, :integer, default: 0, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:epics, [:tenant_id, :project_id, :number])
    create index(:epics, [:tenant_id])
    create index(:epics, [:project_id])

    enable_rls(:epics)
  end
end
