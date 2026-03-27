defmodule Loopctl.Repo.Migrations.CreateRlsInfrastructure do
  use Ecto.Migration

  def up do
    # Create the set_tenant SQL function for use in SET LOCAL
    execute """
    CREATE OR REPLACE FUNCTION set_tenant(tenant_uuid uuid)
    RETURNS void AS $$
    BEGIN
      PERFORM set_config('app.current_tenant_id', tenant_uuid::text, true);
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create a helper function to get the current tenant
    execute """
    CREATE OR REPLACE FUNCTION current_tenant_id()
    RETURNS uuid AS $$
    BEGIN
      RETURN NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    EXCEPTION
      WHEN OTHERS THEN
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql STABLE;
    """

    # Create the tenants table (needed for RLS FK references)
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:slug])

    # Create an RLS test table for integration tests
    create table(:rls_test_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rls_test_records, [:tenant_id])

    # Enable RLS on the test table
    execute "ALTER TABLE rls_test_records ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE rls_test_records FORCE ROW LEVEL SECURITY"

    # Create tenant isolation policy
    execute """
    CREATE POLICY tenant_isolation ON rls_test_records
      USING (tenant_id = current_tenant_id())
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON rls_test_records"
    execute "ALTER TABLE rls_test_records DISABLE ROW LEVEL SECURITY"

    drop table(:rls_test_records)
    drop table(:tenants)

    execute "DROP FUNCTION IF EXISTS current_tenant_id()"
    execute "DROP FUNCTION IF EXISTS set_tenant(uuid)"
  end
end
