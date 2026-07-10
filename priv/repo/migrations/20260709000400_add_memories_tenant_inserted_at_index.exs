defmodule Loopctl.Repo.Migrations.AddMemoriesTenantInsertedAtIndex do
  use Ecto.Migration

  # US-28.3 superadmin oversight (AC-28.3.4). `Loopctl.Memory.list_all_subjects/2`
  # is the tenant-scoped, SUBJECT-AGNOSTIC oversight reader: it filters by
  # `tenant_id` alone, orders `desc: inserted_at, desc: id`, paginates with
  # limit/offset, and runs an unconditional `COUNT` over the same tenant-wide set on
  # every page. The only existing btree on `memories` is (tenant_id, subject_id)
  # (create_memory_stores), which does NOT support a subject-agnostic
  # `ORDER BY inserted_at DESC` — so every oversight page triggered a filtered
  # external sort + offset scan plus a full tenant COUNT. Because the reader is
  # unbounded across subjects (a tenant may have arbitrarily many subjects, each
  # capped only per-subject), this degrades linearly as a tenant grows.
  #
  # This composite index on (tenant_id, inserted_at DESC, id DESC) exactly matches
  # the reader's filter + ordering, so the planner serves both the ordered page and
  # the tenant COUNT from the index. The own-subject `list/2` reader stays served by
  # the (tenant_id, subject_id) btree (it is bounded to one subject).
  #
  # CONCURRENTLY (no table lock) since `memories` is a live OLTP table; the
  # migration lock + DDL transaction are disabled as CREATE INDEX CONCURRENTLY
  # cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "memories_tenant_inserted_at_index"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON memories (tenant_id, inserted_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
