defmodule Loopctl.Repo.Migrations.AddDispatchesExpiresAtActiveIndex do
  use Ecto.Migration

  # Epic 32 (scalability), US-32.1.
  #
  # `Loopctl.Workers.RevokeExpiredDispatchesWorker` runs every 60s via Oban Cron and
  # issues a TENANT-AGNOSTIC (cross-tenant, BYPASSRLS via AdminRepo) sweep:
  #
  #     from(d in Dispatch,
  #       where: is_nil(d.revoked_at) and d.expires_at < ^now,
  #       select: %{id: d.id, api_key_id: d.api_key_id})
  #
  # The only expiry-related index on `dispatches` is the composite
  # (tenant_id, expires_at) from 20260411234856_create_dispatches. Its LEADING column
  # `tenant_id` is absent from the sweep predicate, so Postgres cannot use it → a full
  # seq scan of the continuously-growing `dispatches` table every minute. The sweep MUST
  # stay cross-tenant (it finds expired dispatches across all tenants), so it can never
  # use a tenant-leading index.
  #
  # This partial index matches the sweep predicate exactly — the WHERE
  # `revoked_at IS NULL` clause keeps it tiny (only live, un-revoked rows) and lets the
  # planner serve `expires_at < now()` as an index range scan, making the sweep
  # O(expired rows) instead of O(all dispatches).
  #
  # CONCURRENTLY (no table lock) since `dispatches` is a hot auth/chain-of-custody write
  # path; the migration lock + DDL transaction are disabled because CREATE INDEX
  # CONCURRENTLY cannot run inside a transaction. Purely additive — safe on the live prod
  # DB. Does NOT touch RLS, ownership, or the existing (tenant_id, expires_at) index
  # (other per-tenant lookups still use it).
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "dispatches_expires_at_active_index"

  def up do
    # A CREATE INDEX CONCURRENTLY that fails midway (crash, lock timeout, deploy killed)
    # leaves a permanently-INVALID index behind. On the next deploy, `IF NOT EXISTS`
    # matches that invalid leftover BY NAME and skips the rebuild — the migration records
    # as complete while the index stays unusable and every sweep silently full-scans.
    # Dropping any leftover FIRST (also CONCURRENTLY, IF EXISTS so a clean DB is a no-op)
    # guarantees the CREATE always rebuilds from a known-clean state. Two separate
    # statements are required — each CONCURRENTLY op runs outside a transaction, which is
    # why @disable_ddl_transaction is set.
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON dispatches (expires_at)
      WHERE revoked_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
