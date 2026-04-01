#!/bin/bash
# ==============================================================================
# Fly.io PostgreSQL RLS Role Setup
# ==============================================================================
#
# ONE-TIME MANUAL STEP: Run this SQL via `fly postgres connect -a loopctl-db`
# after provisioning the Fly Postgres cluster.
#
# This creates the two database roles required by loopctl's RLS architecture:
#
#   loopctl_app   — Regular app role. RLS policies are enforced for this role.
#                   Used by Loopctl.Repo (the main application connection pool).
#
#   loopctl_admin — Admin role with BYPASSRLS. RLS policies are NOT enforced.
#                   Used by Loopctl.AdminRepo for migrations and superadmin ops.
#
# IMPORTANT: DATABASE_URL Connection Port
# ----------------------------------------
# Fly Postgres includes PgBouncer on port 5432 (default). PgBouncer uses
# transaction-level pooling which breaks SET LOCAL statements — these are
# required for RLS tenant isolation (SET LOCAL app.current_tenant_id = '...').
#
# You MUST use port 5433 (direct PostgreSQL connection, bypassing PgBouncer)
# in both DATABASE_URL and ADMIN_DATABASE_URL:
#
#   fly secrets set DATABASE_URL="postgres://loopctl_app:PASSWORD@loopctl-db.flycast:5433/loopctl"
#   fly secrets set ADMIN_DATABASE_URL="postgres://loopctl_admin:PASSWORD@loopctl-db.flycast:5433/loopctl"
#
# Port 5432 = PgBouncer (breaks SET LOCAL / RLS)
# Port 5433 = Direct PostgreSQL (required for RLS)
#
# ==============================================================================
# HOW TO RUN:
#
#   1. Connect to Fly Postgres:
#      fly postgres connect -a loopctl-db
#
#   2. Paste the SQL below into the psql session.
#
#   3. Set the passwords as Fly secrets:
#      fly secrets set DATABASE_URL="postgres://loopctl_app:CHOSEN_PASSWORD@loopctl-db.flycast:5433/loopctl"
#      fly secrets set ADMIN_DATABASE_URL="postgres://loopctl_admin:CHOSEN_PASSWORD@loopctl-db.flycast:5433/loopctl"
#
# ==============================================================================

cat <<'SQL'
-- Create application role (RLS enforced)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'loopctl_app') THEN
    CREATE ROLE loopctl_app WITH LOGIN PASSWORD 'CHANGE_ME_APP_PASSWORD';
  END IF;
END $$;

-- Create admin role (BYPASSRLS for migrations and superadmin operations)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'loopctl_admin') THEN
    CREATE ROLE loopctl_admin WITH LOGIN BYPASSRLS PASSWORD 'CHANGE_ME_ADMIN_PASSWORD';
  END IF;
END $$;

-- Grant database-level privileges
GRANT ALL PRIVILEGES ON DATABASE loopctl TO loopctl_app, loopctl_admin;

-- Grant schema-level privileges
GRANT ALL ON ALL TABLES IN SCHEMA public TO loopctl_app, loopctl_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO loopctl_app, loopctl_admin;

-- Ensure future tables/sequences are also accessible
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO loopctl_app, loopctl_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO loopctl_app, loopctl_admin;

-- RLS helper function: returns the current tenant ID set via SET LOCAL
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS uuid AS $$
  SELECT nullif(current_setting('app.current_tenant_id', true), '')::uuid
$$ LANGUAGE sql STABLE;
SQL
