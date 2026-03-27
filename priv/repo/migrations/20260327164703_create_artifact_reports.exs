defmodule Loopctl.Repo.Migrations.CreateArtifactReports do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:artifact_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false

      add :reported_by, :string, null: false
      add :reporter_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :artifact_type, :string, null: false
      add :path, :string
      add :exists, :boolean, default: true
      add :details, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_reports, [:tenant_id])
    create index(:artifact_reports, [:story_id])
    create index(:artifact_reports, [:reporter_agent_id])

    enable_rls(:artifact_reports)
  end
end
