defmodule Loopctl.Repo.Migrations.AddAttributionToArticleAccessEvents do
  use Ecto.Migration

  @moduledoc """
  US-25.1: Wiki Access Event Attribution — Schema & Ingestion

  Adds `project_id` and `story_id` columns to `article_access_events` so that
  every wiki read can be attributed to the project and story the caller was
  working on at the time of the read.

  Both columns are nullable so:

  - rows written before this story remain valid
  - callers without context can still record reads (backward compat)
  - cross-tenant attribution attempts can be silently dropped by the context
    layer without failing the read (see `Loopctl.Knowledge.Analytics`)

  Foreign keys use `ON DELETE SET NULL` (`nilify_all`) so deleting a project
  or story does not destroy the historical access event — it just drops the
  attribution.

  RLS policy on `article_access_events` is NOT modified: `tenant_id` remains
  the sole isolation boundary. `project_id` and `story_id` are reporting
  dimensions, not trust boundaries.
  """

  def change do
    alter table(:article_access_events) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all), null: true

      add :story_id, references(:stories, type: :binary_id, on_delete: :nilify_all), null: true
    end

    # Tenant-first composite indexes with DESC on accessed_at for timeline queries.
    # tenant_id is the first column to match RLS query shapes.
    # Explicit names so US-25.2's EXPLAIN plan test can reference them.
    execute(
      "CREATE INDEX article_access_events_project_id_accessed_at_idx " <>
        "ON article_access_events (tenant_id, project_id, accessed_at DESC)",
      "DROP INDEX IF EXISTS article_access_events_project_id_accessed_at_idx"
    )

    execute(
      "CREATE INDEX article_access_events_story_id_accessed_at_idx " <>
        "ON article_access_events (tenant_id, story_id, accessed_at DESC)",
      "DROP INDEX IF EXISTS article_access_events_story_id_accessed_at_idx"
    )
  end
end
