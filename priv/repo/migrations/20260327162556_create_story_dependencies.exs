defmodule Loopctl.Repo.Migrations.CreateStoryDependencies do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:story_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :depends_on_story_id, references(:stories, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:story_dependencies, [:story_id, :depends_on_story_id])
    create index(:story_dependencies, [:tenant_id])
    create index(:story_dependencies, [:story_id])
    create index(:story_dependencies, [:depends_on_story_id])

    enable_rls(:story_dependencies)
  end
end
