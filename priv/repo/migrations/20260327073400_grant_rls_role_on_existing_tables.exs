defmodule Loopctl.Repo.Migrations.GrantRlsRoleOnExistingTables do
  @moduledoc """
  Grants table privileges to the `loopctl_app` role on all existing
  RLS-enabled tables.

  The `loopctl_app` role is used in dev/test when `SET LOCAL ROLE`
  switches from the superuser to enforce RLS policies. Without these
  grants, the role has no permission to SELECT, INSERT, UPDATE, or
  DELETE on any table, causing "permission denied" errors.

  Future tables should use the `enable_rls/1` macro from
  `Loopctl.Repo.RlsHelpers`, which includes the GRANT automatically.
  """

  use Ecto.Migration

  @rls_tables ~w(rls_test_records api_keys audit_log tenants idempotency_cache)

  def up do
    for table <- @rls_tables do
      execute """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
          EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO loopctl_app';
        END IF;
      END $$;
      """
    end

    # Grant on partitioned audit_log children (pattern: audit_log_y*m*)
    execute """
    DO $$
    DECLARE
      partition_name text;
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
        FOR partition_name IN
          SELECT tablename FROM pg_tables
          WHERE schemaname = 'public'
          AND tablename LIKE 'audit_log_y%'
        LOOP
          EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ' || partition_name || ' TO loopctl_app';
        END LOOP;
      END IF;
    END $$;
    """

    # Set default privileges so future tables created by the migration user
    # automatically grant to loopctl_app
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO loopctl_app';
      END IF;
    END $$;
    """
  end

  def down do
    for table <- @rls_tables do
      execute """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
          EXECUTE 'REVOKE ALL ON #{table} FROM loopctl_app';
        END IF;
      END $$;
      """
    end

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM loopctl_app';
      END IF;
    END $$;
    """
  end
end
