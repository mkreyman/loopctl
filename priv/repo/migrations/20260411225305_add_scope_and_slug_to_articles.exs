defmodule Loopctl.Repo.Migrations.AddScopeAndSlugToArticles do
  use Ecto.Migration

  def change do
    # Add scope enum and slug columns
    alter table(:articles) do
      add :scope, :string, null: false, default: "tenant"
      add :slug, :string
    end

    # Make tenant_id nullable (system articles have no tenant)
    execute(
      "ALTER TABLE articles ALTER COLUMN tenant_id DROP NOT NULL",
      "ALTER TABLE articles ALTER COLUMN tenant_id SET NOT NULL"
    )

    # Scope-tenant consistency: system articles must have null tenant_id
    execute(
      """
      ALTER TABLE articles ADD CONSTRAINT articles_scope_tenant_consistency
        CHECK (
          (scope = 'tenant' AND tenant_id IS NOT NULL) OR
          (scope = 'system' AND tenant_id IS NULL)
        )
      """,
      "ALTER TABLE articles DROP CONSTRAINT IF EXISTS articles_scope_tenant_consistency"
    )

    # System slugs must be globally unique
    create unique_index(:articles, [:slug],
             where: "scope = 'system'",
             name: :articles_system_slug_idx
           )

    # Tenant slugs must be unique per tenant
    create unique_index(:articles, [:tenant_id, :slug],
             where: "scope = 'tenant'",
             name: :articles_tenant_slug_idx
           )

    # Backfill: generate slugs for existing articles from their titles
    execute(
      """
      UPDATE articles
      SET slug = LOWER(REGEXP_REPLACE(REGEXP_REPLACE(title, '[^a-zA-Z0-9 -]', '', 'g'), '\\s+', '-', 'g'))
      WHERE slug IS NULL
      """,
      "SELECT 1"
    )
  end
end
