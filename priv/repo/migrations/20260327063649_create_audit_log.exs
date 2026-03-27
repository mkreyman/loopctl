defmodule Loopctl.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def up do
    # Create the parent partitioned table
    execute """
    CREATE TABLE audit_log (
      id uuid NOT NULL DEFAULT gen_random_uuid(),
      tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE,
      project_id uuid,
      entity_type varchar(255) NOT NULL,
      entity_id uuid NOT NULL,
      action varchar(255) NOT NULL,
      actor_type varchar(255) NOT NULL,
      actor_id uuid,
      actor_label varchar(255),
      old_state jsonb,
      new_state jsonb,
      metadata jsonb DEFAULT '{}'::jsonb,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    # Create initial partitions: current month + 3 months ahead
    now = DateTime.utc_now()

    for offset <- 0..3 do
      {year, month} = month_offset(now.year, now.month, offset)
      {next_year, next_month} = month_offset(year, month, 1)

      partition_name = partition_name(year, month)
      from_date = "#{year}-#{pad(month)}-01"
      to_date = "#{next_year}-#{pad(next_month)}-01"

      execute """
      CREATE TABLE #{partition_name} PARTITION OF audit_log
        FOR VALUES FROM ('#{from_date}') TO ('#{to_date}')
      """
    end

    # Composite index for entity lookups
    execute """
    CREATE INDEX audit_log_tenant_entity_idx
      ON audit_log (tenant_id, entity_type, entity_id)
    """

    # Index for date range queries and change feed polling
    execute """
    CREATE INDEX audit_log_tenant_inserted_at_idx
      ON audit_log (tenant_id, inserted_at)
    """

    # Index for project-scoped change feed queries
    execute """
    CREATE INDEX audit_log_project_id_idx
      ON audit_log (project_id)
      WHERE project_id IS NOT NULL
    """

    # Prevent UPDATE operations on audit_log
    execute """
    CREATE OR REPLACE FUNCTION audit_log_prevent_update()
    RETURNS TRIGGER AS $$
    BEGIN
      RAISE EXCEPTION 'UPDATE on audit_log is not allowed — audit log is append-only';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER audit_log_no_update
      BEFORE UPDATE ON audit_log
      FOR EACH ROW EXECUTE FUNCTION audit_log_prevent_update()
    """

    # Prevent DELETE operations on audit_log
    execute """
    CREATE OR REPLACE FUNCTION audit_log_prevent_delete()
    RETURNS TRIGGER AS $$
    BEGIN
      RAISE EXCEPTION 'DELETE on audit_log is not allowed — audit log is append-only';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER audit_log_no_delete
      BEFORE DELETE ON audit_log
      FOR EACH ROW EXECUTE FUNCTION audit_log_prevent_delete()
    """

    # Enable RLS
    execute "ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE audit_log FORCE ROW LEVEL SECURITY"

    # RLS policy: INSERT allowed for all authenticated roles
    execute """
    CREATE POLICY audit_log_insert ON audit_log
      FOR INSERT
      WITH CHECK (
        tenant_id = current_tenant_id()
        OR tenant_id IS NULL
      )
    """

    # RLS policy: SELECT restricted by tenant_id
    execute """
    CREATE POLICY audit_log_select ON audit_log
      FOR SELECT
      USING (
        tenant_id = current_tenant_id()
        OR tenant_id IS NULL
      )
    """

    # No UPDATE or DELETE policies — RLS blocks them even if triggers don't fire
  end

  def down do
    execute "DROP POLICY IF EXISTS audit_log_select ON audit_log"
    execute "DROP POLICY IF EXISTS audit_log_insert ON audit_log"
    execute "ALTER TABLE audit_log DISABLE ROW LEVEL SECURITY"
    execute "DROP TRIGGER IF EXISTS audit_log_no_delete ON audit_log"
    execute "DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log"
    execute "DROP FUNCTION IF EXISTS audit_log_prevent_delete()"
    execute "DROP FUNCTION IF EXISTS audit_log_prevent_update()"
    execute "DROP TABLE IF EXISTS audit_log CASCADE"
  end

  defp month_offset(year, month, offset) do
    total = year * 12 + month - 1 + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp partition_name(year, month), do: "audit_log_y#{year}m#{pad(month)}"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
