defmodule Loopctl.Repo.Migrations.CreateArticles do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:articles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: true

      add :title, :string, null: false, size: 500
      add :body, :text, null: false
      add :category, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :tags, {:array, :string}, null: false, default: []
      add :source_type, :string, null: true
      add :source_id, :binary_id, null: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Basic tenant scoping index
    create index(:articles, [:tenant_id])

    # GIN index on tags for efficient array containment queries (AC-19.1.5)
    create index(:articles, [:tags], using: :gin)

    # Composite index for filtered listing queries (AC-19.1.6)
    create index(:articles, [:tenant_id, :project_id, :category])

    # Partial unique index on (tenant_id, title) excluding archived/superseded (AC-19.1.7)
    execute(
      "CREATE UNIQUE INDEX articles_tenant_title_active_idx ON articles (tenant_id, title) WHERE status NOT IN ('archived', 'superseded')",
      "DROP INDEX IF EXISTS articles_tenant_title_active_idx"
    )

    # Enable Row Level Security (AC-19.1.8)
    enable_rls(:articles)
  end
end
