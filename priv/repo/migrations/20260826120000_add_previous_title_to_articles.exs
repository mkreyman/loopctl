defmodule Loopctl.Repo.Migrations.AddPreviousTitleToArticles do
  @moduledoc """
  The DURABLE undo record for the nightly `:generic_title` retitle (#765).

  `Loopctl.Knowledge.Consolidation` retitles a confirmed placeholder from the article's own
  content, unattended. What licenses that write is REVERSIBILITY — a class earns an
  automatic consumer by being undoable in code, never by being confident — and an undo needs
  the title that was replaced. Recording it on `metadata` did not survive contact with the
  API: `metadata` is cast and whole-map-REPLACED by `PATCH /api/v1/knowledge/:id`, so one
  ordinary agent request erased the record while leaving the retitle standing. That is the
  `stories.lifecycle_entered_at` lesson (CLAUDE.md) reached a second time by a second
  subsystem.

  The `audit_log` carries the replaced title in `old_state` too, and is retention-bounded
  (`:audit_retention_days`); past that horizon it is gone. A column is the only record that
  is neither erasable by a caller nor expiring.

  **Never add `:previous_title` to a changeset `cast` list.** It is written programmatically
  by `Loopctl.Knowledge.Article.retitle_changeset/2` — reached only through
  `Loopctl.Knowledge.retitle_article/4` — and by nothing else.

  No index: nothing queries BY the previous title. It is read one row at a time, by an
  operator undoing one retitle, on a row already located by id.

  ## The backfill

  Rows retitled before this migration carry the title only on
  `metadata["consolidation_previous_title"]`, where the next PATCH can erase it. Converting
  them while the key still exists is a one-time opportunity. The key itself is left in place
  — a migration that also deleted it would destroy the very record it is rescuing if the
  UPDATE were ever re-run against a partially-migrated table.

  Nullable with no default, so the ALTER is catalog-only on PG11+ — no table rewrite.
  """

  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :previous_title, :text
    end

    execute("""
    UPDATE articles
    SET previous_title = metadata->>'consolidation_previous_title'
    WHERE previous_title IS NULL
      AND metadata->>'consolidation_previous_title' IS NOT NULL
    """)
  end

  def down do
    alter table(:articles) do
      remove :previous_title
    end
  end
end
