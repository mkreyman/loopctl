# Fly.io Deployment Guide for loopctl

## Required Secrets

Set all secrets before first deploy:

```bash
# Database connections — MUST use port 5433 (direct, bypasses PgBouncer) for RLS
fly secrets set DATABASE_URL="postgres://loopctl_app:PASSWORD@loopctl-db.flycast:5433/loopctl"
fly secrets set ADMIN_DATABASE_URL="postgres://loopctl_admin:PASSWORD@loopctl-db.flycast:5433/loopctl"

# Phoenix secret key base (generate with: mix phx.gen.secret)
fly secrets set SECRET_KEY_BASE="GENERATED_SECRET"

# Cloak encryption key (generate with: :crypto.strong_rand_bytes(32) |> Base.encode64())
fly secrets set CLOAK_KEY="GENERATED_BASE64_KEY"
```

### Secret Reference

| Secret             | Required | Description                                         |
|--------------------|----------|-----------------------------------------------------|
| `DATABASE_URL`     | Yes      | Ecto URL for `Loopctl.Repo` (loopctl_app role, RLS enforced) |
| `ADMIN_DATABASE_URL` | Yes    | Ecto URL for `Loopctl.AdminRepo` (loopctl_admin role, BYPASSRLS) |
| `SECRET_KEY_BASE`  | Yes      | Phoenix cookie signing/encryption key               |
| `CLOAK_KEY`        | Yes      | AES-256-GCM encryption key for API key hashing      |

### Environment Variables (set in fly.toml, not secrets)

| Variable       | Value          | Description                    |
|----------------|----------------|--------------------------------|
| `PHX_HOST`     | `loopctl.com`  | Canonical hostname             |
| `PORT`         | `8080`         | HTTP listener port             |
| `PHX_SERVER`   | `true`         | Start Phoenix server on boot   |

### Optional Environment Variables

| Variable            | Default | Description                              |
|---------------------|---------|------------------------------------------|
| `POOL_SIZE`         | `10`    | Repo connection pool size                |
| `ADMIN_POOL_SIZE`   | `3`     | AdminRepo connection pool size           |
| `ECTO_IPV6`         | -       | Set to `true` to enable IPv6 for DB     |
| `DNS_CLUSTER_QUERY` | -       | DNS query for clustering (not needed for single machine) |

## Database Setup

**Before first deploy**, provision the Fly Postgres cluster and run the RLS role setup:

1. Create the Postgres cluster:
   ```bash
   fly postgres create --name loopctl-db --region lax
   ```

2. Attach to the app (creates the `loopctl` database):
   ```bash
   fly postgres attach loopctl-db -a loopctl
   ```

3. Connect and run the role setup SQL from `deploy/fly-db-setup.sh`:
   ```bash
   fly postgres connect -a loopctl-db
   # Paste the SQL from deploy/fly-db-setup.sh
   ```

4. Set the secrets with the chosen passwords (port 5433 is critical):
   ```bash
   fly secrets set DATABASE_URL="postgres://loopctl_app:PASSWORD@loopctl-db.flycast:5433/loopctl"
   fly secrets set ADMIN_DATABASE_URL="postgres://loopctl_admin:PASSWORD@loopctl-db.flycast:5433/loopctl"
   ```

**Why port 5433?** Fly Postgres runs PgBouncer on port 5432. PgBouncer uses
transaction-level pooling which breaks `SET LOCAL` statements required for RLS
tenant isolation. Port 5433 connects directly to PostgreSQL.

## DNS Setup

loopctl.com is an apex (naked) domain. CNAME records are not allowed on apex
domains per RFC 1034. Use A records pointing to Fly's anycast IP addresses.

1. Get Fly.io's dedicated IPv4 address:
   ```bash
   fly ips allocate-v4 -a loopctl
   ```

2. Configure DNS at your registrar:
   ```
   A     loopctl.com    → <fly-ipv4-address>
   AAAA  loopctl.com    → <fly-ipv6-address>  (optional, from fly ips list)
   ```

3. Issue the TLS certificate:
   ```bash
   fly certs add loopctl.com -a loopctl
   ```

4. Verify certificate status:
   ```bash
   fly certs show loopctl.com -a loopctl
   ```

## Deployment

Deployments happen automatically via GitHub Actions on push to `master`.

Manual deploy:
```bash
fly deploy
```

## Post-Deploy Verification

After each deployment, verify the application is healthy:

1. **Health check endpoint**:
   ```bash
   curl -s https://loopctl.com/health | jq .
   # Expected: {"status":"ok","version":"0.1.0","checks":{"database":"ok","oban":"ok"}}
   ```

2. **Fly machine status**:
   ```bash
   fly status -a loopctl
   fly logs -a loopctl
   ```

3. **Database connectivity**:
   ```bash
   fly ssh console -a loopctl -C "/app/bin/loopctl eval 'Loopctl.Repo.query!(\"SELECT 1\")'"
   ```

4. **Migration status**:
   ```bash
   fly ssh console -a loopctl -C "/app/bin/loopctl eval 'Loopctl.Release.migrate()'"
   ```

5. **API smoke test** (replace with a valid API key):
   ```bash
   curl -s -H "Authorization: Bearer API_KEY" https://loopctl.com/api/v1/projects | jq .
   ```
