defmodule Loopctl.Repo.Migrations.CreateProjects do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :repo_url, :string
      add :description, :text
      add :tech_stack, :string
      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:tenant_id, :slug])
    create index(:projects, [:tenant_id])
    create index(:projects, [:status])

    enable_rls(:projects)
  end
end
