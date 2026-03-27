defmodule Loopctl.Repo.Migrations.CreateSkillResults do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:skill_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :skill_version_id,
          references(:skill_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :verification_result_id,
          references(:verification_results, type: :binary_id, on_delete: :delete_all),
          null: false

      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :metrics, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skill_results, [:tenant_id])
    create index(:skill_results, [:skill_version_id])
    create index(:skill_results, [:verification_result_id])
    create index(:skill_results, [:story_id])

    enable_rls(:skill_results)
  end
end
