defmodule Loopctl.Repo.Migrations.CreateEpicDependencies do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:epic_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :epic_id, references(:epics, type: :binary_id, on_delete: :delete_all), null: false

      add :depends_on_epic_id, references(:epics, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:epic_dependencies, [:epic_id, :depends_on_epic_id])
    create index(:epic_dependencies, [:tenant_id])
    create index(:epic_dependencies, [:epic_id])
    create index(:epic_dependencies, [:depends_on_epic_id])

    enable_rls(:epic_dependencies)
  end
end
