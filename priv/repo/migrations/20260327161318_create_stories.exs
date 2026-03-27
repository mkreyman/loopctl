defmodule Loopctl.Repo.Migrations.CreateStories do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:stories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :epic_id, references(:epics, type: :binary_id, on_delete: :delete_all), null: false

      add :number, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :acceptance_criteria, :map
      add :estimated_hours, :decimal
      add :agent_status, :string, null: false, default: "pending"
      add :verified_status, :string, null: false, default: "unverified"
      add :assigned_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :assigned_at, :utc_datetime_usec
      add :reported_done_at, :utc_datetime_usec
      add :verified_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      add :rejection_reason, :text
      add :sort_key, :integer, null: false, default: 0
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Project-wide uniqueness for story numbers
    create unique_index(:stories, [:tenant_id, :project_id, :number])
    create index(:stories, [:tenant_id])
    create index(:stories, [:project_id])
    create index(:stories, [:epic_id])
    create index(:stories, [:tenant_id, :agent_status])
    create index(:stories, [:tenant_id, :verified_status])
    create index(:stories, [:assigned_agent_id])

    enable_rls(:stories)
  end
end
