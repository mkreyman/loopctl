defmodule Loopctl.Repo.Migrations.DropAuditLogTenantFk do
  use Ecto.Migration

  def up do
    # The FK was created inline in the CREATE TABLE statement in the original
    # migration. PostgreSQL auto-names it audit_log_tenant_id_fkey.
    #
    # This FK causes ShareRowExclusiveLock during concurrent inserts, leading
    # to deadlocks under async test execution and high production concurrency.
    # Since audit_log is append-only (enforced by triggers), tenant_id is always
    # set programmatically, and tenants are never deleted, the FK provides no value.
    execute "ALTER TABLE audit_log DROP CONSTRAINT IF EXISTS audit_log_tenant_id_fkey"
  end

  def down do
    execute """
    ALTER TABLE audit_log
      ADD CONSTRAINT audit_log_tenant_id_fkey
      FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
    """
  end
end
