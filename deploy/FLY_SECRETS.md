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
| `CLOAK_KEY`        | Yes      | AES-256-GCM key for every field encrypted at rest: API key hashing, tenant LLM keys, webhook signing secrets, and ingestion document content |

> **Rotating `CLOAK_KEY`:** keep the OUTGOING cipher in `Loopctl.Vault`'s
> `retired_ciphers` (see `config/config.exs`) until the `:ingestion` queue has
> drained. Ingestion jobs carry their document encrypted in `oban_jobs.args` and
> live up to the 3600s uniqueness window (longer under snooze); a rotation that
> drops the old cipher first makes those in-flight jobs undecryptable, and they
> discard. The worker logs a distinct warning on every decrypt failure — alert on
> it, since the same signal also means at-rest tampering.

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
| `SECRETS_ADAPTER`   | Fly GraphQL | Set to `local_file` to store the per-tenant audit keypairs on disk instead of in Fly secrets — REQUIRED when self-hosting off Fly (see below) |
| `SECRETS_FILE`      | `/data/loopctl/secrets.json` | Path for the `local_file` adapter. Put it on a PERSISTENT volume |
| `FTS_REGCONFIG`     | `english` | Postgres text-search config for keyword FTS (see below) |

#### Self-hosting off Fly: `SECRETS_ADAPTER=local_file`

Tenant signup mints a per-tenant Ed25519 audit keypair and stores the private key
through `Loopctl.Secrets`. The default adapter writes to **Fly secrets**, so on a
non-Fly host signup fails and no tenant can be created. Switch it:

```bash
SECRETS_ADAPTER=local_file
SECRETS_FILE=/data/loopctl/secrets.json   # must be on a persistent volume
```

The local adapter writes `0600`, fsyncs, and uses an atomic tmp+rename under a
write lock. **Back this file up with the database** — losing it breaks audit-chain
signature verification for every tenant it holds a key for.

#### Non-English knowledge bases: `FTS_REGCONFIG`

Keyword full-text search ships hardwired to the `english` stemmer, which does not
unify inflected forms in other languages (Russian «отчёты» never matches «отчёт»)
and applies the wrong stop-words. Set the deployment's Postgres text-search
configuration:

```bash
FTS_REGCONFIG=russian   # any name in pg_ts_config: simple, french, german, ...
```

**Set it BEFORE the first `migrate` on a fresh install.** The `apply_fts_regconfig`
migration bakes the value into the stored `search_vector`s (a generated column cannot
read runtime config), and it is a no-op on the `english` default. Changing the value
on an already-migrated corpus does NOT re-run that migration — rebuilding a populated
corpus's vectors is a separate operator action.

A name that is well-formed but **not installed** (e.g. `ukrainian`, which stock
Postgres does not ship) fails the migration loudly rather than silently building an
unusable index — install the dictionary first. Verify with:

```sql
SELECT cfgname FROM pg_ts_config ORDER BY cfgname;
```

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
