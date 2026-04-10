defmodule Loopctl.Repo.Migrations.CreateArticleLinks do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  def change do
    create table(:article_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :source_article_id, references(:articles, type: :binary_id, on_delete: :restrict),
        null: false

      add :target_article_id, references(:articles, type: :binary_id, on_delete: :restrict),
        null: false

      add :relationship_type, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Composite unique index: one link per (tenant, source, target, type)
    create unique_index(
             :article_links,
             [:tenant_id, :source_article_id, :target_article_id, :relationship_type],
             name: :article_links_tenant_src_tgt_rel_index
           )

    # Basic tenant scoping index
    create index(:article_links, [:tenant_id])

    # Index for efficient lookup of outgoing links from an article
    create index(:article_links, [:source_article_id])

    # Index for efficient lookup of incoming links to an article
    create index(:article_links, [:target_article_id])

    # Enable Row Level Security
    enable_rls(:article_links)
  end
end
