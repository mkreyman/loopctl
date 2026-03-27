defmodule Loopctl.Repo.Migrations.CreateSkills do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    # Skills table
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :name, :string, null: false
      add :description, :text
      add :current_version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skills, [:tenant_id])
    create unique_index(:skills, [:tenant_id, :name], name: :skills_tenant_id_name_index)
    create index(:skills, [:tenant_id, :project_id])
    create index(:skills, [:tenant_id, :status])

    enable_rls(:skills)

    # Skill versions table (immutable)
    create table(:skill_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :skill_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :prompt_text, :text, null: false
      add :changelog, :text
      add :created_by, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_versions, [:tenant_id])
    create index(:skill_versions, [:skill_id])

    create unique_index(:skill_versions, [:skill_id, :version],
             name: :skill_versions_skill_id_version_index
           )

    enable_rls(:skill_versions)
  end
end
