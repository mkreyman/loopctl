defmodule Loopctl.Repo.RlsHelpers do
  @moduledoc """
  Migration helpers for enabling PostgreSQL Row Level Security on tables.

  Use these in migrations to consistently apply RLS policies to tenant-scoped tables.

  ## Usage in migrations

      defmodule Loopctl.Repo.Migrations.CreateProjects do
        use Ecto.Migration
        import Loopctl.Repo.RlsHelpers

        def change do
          create table(:projects, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :tenant_id, references(:tenants, type: :binary_id), null: false
            add :name, :string
            timestamps(type: :utc_datetime_usec)
          end

          enable_rls(:projects)
        end
      end
  """

  @doc """
  Enables RLS on a table and creates a tenant isolation policy.

  This is idempotent — running it multiple times does not produce errors.

  Executes:
  1. `ALTER TABLE <table> ENABLE ROW LEVEL SECURITY`
  2. `ALTER TABLE <table> FORCE ROW LEVEL SECURITY`
  3. Creates a `tenant_isolation` policy using `current_tenant_id()`
  4. Grants ALL privileges to the `loopctl_app` role (used in test/dev
     when `SET LOCAL ROLE` switches from superuser)
  """
  defmacro enable_rls(table) do
    quote do
      table_name = unquote(table) |> to_string()

      Ecto.Migration.execute(
        "ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY"
      )

      Ecto.Migration.execute(
        "ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY",
        "SELECT 1"
      )

      Ecto.Migration.execute(
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE tablename = '#{table_name}'
            AND policyname = 'tenant_isolation'
          ) THEN
            EXECUTE 'CREATE POLICY tenant_isolation ON #{table_name} USING (tenant_id = current_tenant_id())';
          END IF;
        END $$;
        """,
        "DROP POLICY IF EXISTS tenant_isolation ON #{table_name}"
      )

      Ecto.Migration.execute(
        """
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
            EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON #{table_name} TO loopctl_app';
          END IF;
        END $$;
        """,
        """
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'loopctl_app') THEN
            EXECUTE 'REVOKE ALL ON #{table_name} FROM loopctl_app';
          END IF;
        END $$;
        """
      )
    end
  end
end
