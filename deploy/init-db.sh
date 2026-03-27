#!/bin/bash
# PostgreSQL initialization script.
# Runs once when the pgdata volume is first created.
# Creates the RLS-restricted app role and the BYPASSRLS admin role.
set -euo pipefail

DB_APP_USER="${DB_APP_USER:-loopctl_app}"
DB_APP_PASSWORD="${DB_APP_PASSWORD:-loopctl_app_pass}"
DB_ADMIN_USER="${DB_ADMIN_USER:-loopctl_admin}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-loopctl_admin_pass}"
DB_NAME="${POSTGRES_DB:-loopctl_prod}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" <<-EOSQL
  -- Application role (RLS enforced)
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_APP_USER}') THEN
      CREATE ROLE ${DB_APP_USER} LOGIN PASSWORD '${DB_APP_PASSWORD}';
    END IF;
  END \$\$;

  GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_APP_USER};
  GRANT USAGE, CREATE ON SCHEMA public TO ${DB_APP_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_APP_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_APP_USER};

  -- Admin role (BYPASSRLS for superadmin operations)
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_ADMIN_USER}') THEN
      CREATE ROLE ${DB_ADMIN_USER} LOGIN PASSWORD '${DB_ADMIN_PASSWORD}' BYPASSRLS;
    END IF;
  END \$\$;

  GRANT ALL ON DATABASE ${DB_NAME} TO ${DB_ADMIN_USER};
  GRANT ALL ON SCHEMA public TO ${DB_ADMIN_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_ADMIN_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_ADMIN_USER};
EOSQL
