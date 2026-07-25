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

#### Connection pools and query budgets

| Variable                          | Default | Description |
|-----------------------------------|---------|-------------|
| `REPLICA_DATABASE_URL`            | -       | Read DSN for the `HeavyReadRepo` pool (US-38.1). **Defaults off** — unset, heavy reads run against the primary. Pointing this at a replica is a deliberate, gated infra operation: verify replication lag before enabling, since heavy/vector reads then serve possibly-stale rows |
| `HEAVY_READ_POOL_SIZE`            | `8`     | `HeavyReadRepo` pool size. This pool exists so a heavy analytical/vector read cannot starve the 3-connection AdminRepo pool |
| `HEAVY_READ_STATEMENT_TIMEOUT_MS` | `10000` | Per-statement timeout on the heavy-read pool — the backstop that keeps one pathological vector scan from pinning a connection |
| `SLOW_QUERY_THRESHOLD_MS`         | `1000`  | Queries slower than this are logged for diagnosis |

#### Rate limiting and auth-path throttle

| Variable                            | Default | Description |
|-------------------------------------|---------|-------------|
| `RATE_LIMITER`                      | node-local ETS | Set to `postgres` to select the shared Postgres-backed limiter so a MULTI-NODE deployment enforces one cluster-wide budget instead of `limit × node_count`. Provisions nothing (the counter table ships in a migration). Any other value keeps the node-local ETS behaviour |
| `AUTH_THROTTLE_MAX_REQUESTS_PER_IP` | `3000`  | Per-IP request cap on the API-key auth path, per window. Raise it for a shared-egress/NAT deployment where many legitimate keys share one outbound IP |
| `AUTH_THROTTLE_WINDOW_MS`           | `60000` | Window for the per-IP auth throttle |
| `HAMMER_POOL_SIZE`                  | `20`    | Poolboy worker pool fronting every rate-limit check. Sized above Hammer's default of 4 so the fail-CLOSED auth throttle cannot saturate the pool under a single-IP flood |
| `HAMMER_POOL_MAX_OVERFLOW`          | `10`    | Overflow workers for that pool |

> All five accept only a **positive integer** (where numeric). An unset, blank, or
> malformed value leaves the compiled default in place rather than crashing release
> boot — a deliberate choice after the `STH_SWEEP_CRON` incident, so a bad
> placeholder can never take the app down at startup.

#### Metrics and scale alerting

| Variable                    | Default | Description |
|-----------------------------|---------|-------------|
| `METRICS_PORT`              | `9568`  | INTERNAL Prometheus listener (never the public `8080` service); scraped over Fly's private 6PN network. **Must stay in lockstep with the `[metrics]` block in `fly.toml`** |
| `METRICS_TENANT_LABEL_CAP`  | `1000`  | Max distinct tenant label values before the per-tenant metric dimension is collapsed — bounds Prometheus cardinality |
| `SCALE_ALERT_WEBHOOK_URL`   | -       | **Alerting is opt-in until this is set.** With no URL, threshold breaches are only logged, never POSTed. Point it at a Slack / PagerDuty / generic webhook |
| `SCALE_ALERT_CHECK_INTERVAL_MS`         | `60000`  | How often thresholds are evaluated |
| `SCALE_ALERT_RENOTIFY_INTERVAL_MS`      | `900000` | Re-notify interval for a breach that stays open (15 min) |
| `SCALE_ALERT_P95_LATENCY_MS`            | `2000`   | Request p95 latency breach threshold |
| `SCALE_ALERT_QUEUE_TIME_P95_MS`         | `500`    | Oban queue-time p95 breach threshold |
| `SCALE_ALERT_TIMEOUT_RATE_PER_MIN`      | `5`      | Request-timeout rate breach threshold |
| `SCALE_ALERT_OBAN_DISCARD_RATE_PER_MIN` | `10`     | Oban job-discard rate breach threshold |
| `SCALE_ALERT_PROVIDER_ERROR_RATE_PER_MIN` | `10`   | LLM/embedding provider error rate breach threshold |
| `SCALE_ALERT_UNDER_FILL_RATE_PER_MIN`   | `30`     | Under-fill rate breach threshold |

#### LLM / embedding provider

| Variable                  | Default | Description |
|---------------------------|---------|-------------|
| `OPENAI_BASE_URL`         | `https://api.openai.com/v1` | Override to point embeddings at an OpenAI-compatible endpoint (e.g. a local Ollama / vLLM server) |
| `OPENAI_EMBEDDING_MODEL`  | `text-embedding-3-small` | Embedding model name |
| `LOCAL_ENDPOINT_ALLOWLIST` | -      | Comma-separated hosts/CIDRs that the egress guard may reach despite being private/loopback — e.g. `127.0.0.1,localhost,ollama.internal,10.1.0.0/16`. Required to use a LOCAL model endpoint, since the SSRF denylist otherwise refuses private addresses |

#### Feature flags

| Variable                               | Default | Description |
|----------------------------------------|---------|-------------|
| `RLS_REROUTE_LIST_STORIES_BY_PROJECT`  | `false` | Set to `true`/`1` to route `list_stories` through the project-scoped RLS path |

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
