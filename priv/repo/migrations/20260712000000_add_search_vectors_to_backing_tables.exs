defmodule Loopctl.Repo.Migrations.AddSearchVectorsToBackingTables do
  @moduledoc """
  US-30.3 / AC-30.3.4 — adds INDEXED full-text search columns to the phase-1
  Context-Retriever backing tables (`stories`, `projects`, `epics`).

  Each table gets a `search_vector` generated `tsvector` column covering ONLY
  that source's allowlisted TEXT columns (US-30.1 `@column_allowlist`), plus a
  GIN index over it. `Loopctl.ContextRetriever.Executor` runs
  `search_vector @@ websearch_to_tsquery('english', ?)` against this column so
  full-text search hits the GIN index instead of an on-the-fly `to_tsvector`
  sequential scan (and never `ILIKE`).

  Column weights mirror the `articles.search_vector` precedent
  (`20260410021836_add_search_vector_to_articles.exs`): the primary title/name
  field is weight `A`, secondary description/mission text `B`/`C`.

  These tables already have RLS enabled — this migration only adds a column and
  an index, so it does NOT touch RLS.
  """

  use Ecto.Migration

  def up do
    # stories: title (A) + description (B)
    execute """
    ALTER TABLE stories ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(description, '')), 'B')
    ) STORED
    """

    execute "CREATE INDEX stories_search_vector_idx ON stories USING GIN (search_vector)"

    # projects: name (A) + description (B) + mission (C)
    execute """
    ALTER TABLE projects ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(description, '')), 'B') ||
      setweight(to_tsvector('english', coalesce(mission, '')), 'C')
    ) STORED
    """

    execute "CREATE INDEX projects_search_vector_idx ON projects USING GIN (search_vector)"

    # epics: title (A) + description (B)
    execute """
    ALTER TABLE epics ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(description, '')), 'B')
    ) STORED
    """

    execute "CREATE INDEX epics_search_vector_idx ON epics USING GIN (search_vector)"
  end

  def down do
    execute "DROP INDEX IF EXISTS epics_search_vector_idx"
    execute "ALTER TABLE epics DROP COLUMN IF EXISTS search_vector"

    execute "DROP INDEX IF EXISTS projects_search_vector_idx"
    execute "ALTER TABLE projects DROP COLUMN IF EXISTS search_vector"

    execute "DROP INDEX IF EXISTS stories_search_vector_idx"
    execute "ALTER TABLE stories DROP COLUMN IF EXISTS search_vector"
  end
end
