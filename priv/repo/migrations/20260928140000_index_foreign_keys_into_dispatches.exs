defmodule Loopctl.Repo.Migrations.IndexForeignKeysIntoDispatches do
  use Ecto.Migration

  # Two foreign keys into `dispatches` had no index on the referencing column:
  # `dispatches.parent_dispatch_id` (its own self-reference) and
  # `story_acceptance_criteria.verified_by_dispatch_id`. Deleting a dispatch runs one
  # referential check per deleted row against each referencing table, and without an index
  # each check is a scan of that table, so deleting N dispatches costs N scans. Measured
  # 2026-09-28: deleting 20k seeded dispatches did not finish inside a test's exit. Every
  # path that deletes dispatches in bulk pays it, tenant teardown included.
  #
  # Partial on IS NOT NULL: the checks look up a non-null id, most dispatches have no parent,
  # and most criteria were never verified by a dispatch, so the NULL rows would only make
  # the indexes bigger.
  #
  # CONCURRENTLY, with the DDL transaction and migration lock off, because `dispatches` is a
  # hot write path. Each index is dropped first (CONCURRENTLY, IF EXISTS) so an interrupted
  # build's INVALID leftover is rebuilt rather than matched by name and skipped, the same
  # reasoning as 20260713000000_add_dispatches_expires_at_active_index.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {"dispatches_parent_dispatch_id_index", "dispatches", "parent_dispatch_id"},
    {"story_acceptance_criteria_verified_by_dispatch_id_index", "story_acceptance_criteria",
     "verified_by_dispatch_id"}
  ]

  def up do
    for {name, table, column} <- @indexes do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")

      execute("""
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name}
        ON #{table} (#{column})
        WHERE #{column} IS NOT NULL
      """)
    end
  end

  def down do
    for {name, _table, _column} <- @indexes do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
    end
  end
end
