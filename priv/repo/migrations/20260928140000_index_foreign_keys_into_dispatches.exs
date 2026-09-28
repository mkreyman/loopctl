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
  # hot write path. An interrupted CONCURRENTLY build leaves an INVALID index that
  # `IF NOT EXISTS` would match by name and skip, so each index is dropped first, but ONLY
  # when it exists invalid or in another shape (`stale?/2`, the same reconciliation as
  # 20260919100000_add_runner_unsupported_kind_index). Dropping unconditionally would, on a
  # re-run after the second build failed, drop the first index while it was valid and leave
  # the hot table without it for a whole rebuild.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {"dispatches_parent_dispatch_id_index", "dispatches", "parent_dispatch_id"},
    {"story_acceptance_criteria_verified_by_dispatch_id_index", "story_acceptance_criteria",
     "verified_by_dispatch_id"}
  ]

  def up do
    for {name, table, column} <- @indexes do
      if stale?(name, shape(table, column)),
        do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")

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

  defp shape(table, column) do
    ~r/^CREATE INDEX \S+ ON public\.#{table} USING btree \(#{column}\) WHERE \(#{column} IS NOT NULL\)$/
  end

  # True when an index of this name exists but is INVALID or not the shape above; false
  # when it is absent (the CREATE builds it) or already valid in this shape (nothing to do).
  defp stale?(name, shape) do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid
      FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case repo().query!(sql, [name]).rows do
      [[indexdef, true]] -> not (indexdef =~ shape)
      rows -> rows != []
    end
  end
end
