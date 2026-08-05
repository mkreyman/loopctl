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
| `ADMIN_POOL_SIZE`   | `3`     | AdminRepo connection pool size. **Must be >= 2**: the heat index admits at `pool - 1`, so at a pool of 1 it admits nothing and `GET /api/v1/knowledge/heat_index` returns 429 permanently — operator config, not backpressure. An unreadable pool config fails OPEN to this default rather than disabling the endpoint. |
| `ECTO_IPV6`         | -       | Set to `true` to enable IPv6 for DB     |
| `DNS_CLUSTER_QUERY` | -       | DNS query for clustering (not needed for single machine) |
| `WEBAUTHN_RP_ID`    | `loopctl.com` | **Required for any self-hosted deployment on its own domain (#511).** The WebAuthn relying-party id. The spec requires it to be a registrable domain suffix of the page's origin, so while it says `loopctl.com` the browser REFUSES the enrollment ceremony anywhere else — and without enrollment a tenant can never become `human_anchored`, which gates the whole chain-of-custody surface. Set it to the host you serve the signup page from (`wiki.example.com`) or to a registrable parent of it (`example.com`) — a bare host, no scheme, no port, no path. A blank or malformed value is ignored — the boot log names it and the hosted default stays in place, as it does when the variable is unset. **Effectively write-once:** enrolled credentials are cryptographically bound to it (rpIdHash), so changing it on a deployment that already has authenticators fails every later ceremony closed and forces re-enrollment. Set it before the first signup |
| `WEBAUTHN_ORIGIN`   | `https://$PHX_HOST` | The exact page origin the ceremony is served from, as `scheme://host[:port]` — no trailing slash, no path, since Wax compares it to the browser's `clientDataJSON.origin` by exact string (a malformed value is named in the boot log and ignored). The default applies whenever `PHX_HOST` is set, independently of `WEBAUTHN_RP_ID`, and is correct for a normal https deployment even when `WEBAUTHN_RP_ID` is a parent domain of it; with `PHX_HOST` unset nothing is derived (its `example.com` placeholder is not an origin you supplied) and the compiled default stands. **Set it explicitly** for localhost or a non-standard port (`http://localhost:4000`), or when the public origin differs from `PHX_HOST` — WebAuthn only runs in a secure context, with localhost as the sole `http://` exception, so any other `http://` origin fails in the browser regardless of what is configured here |
| `WEBAUTHN_RP_NAME`  | `loopctl`   | Display name the authenticator shows during enrollment. Cosmetic |
| `SECRETS_ADAPTER`   | Fly GraphQL | Set to `local_file` to store the per-tenant audit keypairs on disk instead of in Fly secrets — REQUIRED when self-hosting off Fly (see below) |
| `SECRETS_FILE`      | `/data/loopctl/secrets.json` | Path for the `local_file` adapter. Put it on a PERSISTENT volume |
| `FLY_APP_NAME`      | injected by Fly | The app the DEFAULT (Fly GraphQL) secrets adapter writes tenant audit keys to. Fly Machines set this for you, so it only needs setting when running the Fly adapter off Fly — a case better served by `SECRETS_ADAPTER=local_file` |
| `FLY_API_TOKEN`     | -       | API token the Fly secrets adapter authenticates with (`fly tokens create deploy`). **Not injected** — with either it or `FLY_APP_NAME` missing, the adapter refuses every write with `fly_not_configured`, and since tenant signup mints and stores a per-tenant Ed25519 audit keypair, no tenant can be created. Unset it and use `local_file` when self-hosting |
| `FTS_REGCONFIG`     | `english` | Postgres text-search config for keyword FTS (see below) |

#### Connection pools and query budgets

| Variable                          | Default | Description |
|-----------------------------------|---------|-------------|
| `REPLICA_DATABASE_URL`            | -       | Read DSN for the `HeavyReadRepo` pool (US-38.1). **Defaults off** — unset, heavy reads run against the primary. Pointing this at a replica is a deliberate, gated infra operation: verify replication lag before enabling, since heavy/vector reads then serve possibly-stale rows |
| `HEAVY_READ_POOL_SIZE`            | `8`     | `HeavyReadRepo` pool size. This pool exists so a heavy analytical/vector read cannot starve the 3-connection AdminRepo pool |
| `HEAVY_READ_STATEMENT_TIMEOUT_MS` | `10000` | Per-statement timeout on the heavy-read pool — the backstop that keeps one pathological vector scan from pinning a connection |
| `SLOW_QUERY_THRESHOLD_MS`         | `1000`  | Queries slower than this are logged for diagnosis |
| `EXPECTED_APP_NODES`              | `2`     | How many app nodes the boot-time connection-budget check assumes when it multiplies the per-node pools out against Postgres `max_connections`. Advisory — it only logs, and never blocks boot — but it is the one place that notices a pool sizing that works on one node and exhausts the server on a scaled-out fleet, so **set it to the real machine count** when you scale past two. Anything that is not a positive integer — including a `0` templated from a scale-to-zero machine count — is named in the boot log and falls back to the default, which costs you the accuracy of the check but never the boot |

#### Rate limiting and auth-path throttle

| Variable                            | Default | Description |
|-------------------------------------|---------|-------------|
| `RATE_LIMITER`                      | node-local ETS | Set to `postgres` to select the shared Postgres-backed limiter so a MULTI-NODE deployment enforces one cluster-wide budget instead of `limit × node_count`. Provisions nothing (the counter table ships in a migration). Any other value keeps the node-local ETS behaviour |
| `AUTH_THROTTLE_MAX_REQUESTS_PER_IP` | `3000`  | Per-IP request cap on the API-key auth path, per window. Raise it for a shared-egress/NAT deployment where many legitimate keys share one outbound IP |
| `AUTH_THROTTLE_WINDOW_MS`           | `60000` | Window for the per-IP auth throttle |
| `HAMMER_POOL_SIZE`                  | `20`    | Poolboy worker pool fronting every rate-limit check. Sized above Hammer's default of 4 so the fail-CLOSED auth throttle cannot saturate the pool under a single-IP flood |
| `HAMMER_POOL_MAX_OVERFLOW`          | `10`    | Overflow workers for that pool |

> The four numeric knobs in the table directly above (`AUTH_THROTTLE_MAX_REQUESTS_PER_IP`,
> `AUTH_THROTTLE_WINDOW_MS`, `HAMMER_POOL_SIZE`, `HAMMER_POOL_MAX_OVERFLOW`) accept only a
> **positive integer**. An unset, blank, or malformed value leaves the compiled default in
> place rather than crashing release boot — a deliberate choice after the `STH_SWEEP_CRON`
> incident, so a bad placeholder can never take *those* down at startup. The Oban knobs
> below do NOT share that behaviour: each raises on a malformed value.

#### Oban scheduling and fair-share yield

| Variable                               | Default       | Description |
|----------------------------------------|---------------|-------------|
| `STH_SWEEP_CRON`                       | `*/5 * * * *` | Cron for the all-tenants Signed-Tree-Head safety sweep. A load/latency knob only: every job it fans out self-gates on whether an STH is actually needed, so slowing it delays (never corrupts) an STH for a tenant the event path also missed, by at most one interval. Accepts anything Oban's own Cron parser accepts, `@`-nicknames included. Unlike the knobs above, a present-but-malformed value **raises at boot** rather than falling back — the fallback is what made the original incident silent |
| `OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS` | `5`           | Base snooze, in seconds, for a job that yields its slot to a tenant with less work executing. Positive integer, else raises. Raise it to cut re-check churn on a busy queue; too high starves the yielding tenant, since a snoozed job re-competes only after it elapses |
| `OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER`  | `5`           | Span added on top as `base + rand(0..jitter)`, so a batch of jobs snoozed together does not re-check in lockstep. Non-negative integer — `0` disables jitter and is the thundering-herd shape; else raises |
| `OBAN_QUEUE_<QUEUE>`                   | per queue     | Width (concurrency) of one Oban queue, one variable per queue — `OBAN_QUEUE_EMBEDDINGS=8` and restart, no deploy. Defaults: `DEFAULT` 9, `WEBHOOKS` 5, `EMBEDDINGS` 5, `ANALYTICS`/`KNOWLEDGE`/`MEMORY`/`AUDIT` 3, `CLEANUP`/`MAINTENANCE`/`INGESTION` 2, `VERIFICATION` 1. Positive integer, else raises at boot — a `0` would starve the queue silently |
| `OBAN_TENANT_FAIRSHARE_<QUEUE>`        | `ceil(width/2)` | Per-tenant cap on a queue's EXECUTING slots before that tenant's next job snoozes, one variable per queue (same names as above), so one tenant cannot monopolise a contended queue. DERIVED from the current width, so retuning `OBAN_QUEUE_<QUEUE>` rescales it — set this only to loosen fairness mid-incident. Positive integer, else raises at boot; the effective value is never below 1, or the gate could wedge the queue |

#### Ingestion backlog gate

Per-tenant backpressure on `POST /api/v1/knowledge/ingest` and `/ingest/batch`, so one
tenant cannot monopolise the `:ingestion` queue. Read at call time, so both are tunable
during an incident with `fly secrets set … && fly apps restart` — no deploy.

| Variable                          | Default | Description |
|-----------------------------------|---------|-------------|
| `OBAN_INGEST_BACKLOG_MAX`         | `500`   | In-flight `:ingestion` jobs at/above which a tenant's ingest requests get `429 ingestion_backlog_exceeded`. A SOFT admission floor, not a hard cap — the check is a lock-free read-then-enqueue, so concurrent requests can overshoot it by the in-flight request concurrency. Read it as "start shedding around here". **It also derives the fail-open allowance** (see below), so tightening it tightens both |
| `OBAN_INGEST_BACKLOG_RETRY_AFTER` | `60`    | Seconds advised in `Retry-After` on an OVER-THRESHOLD backlog refusal. Scaled to the queue's DRAIN cadence (jobs are multi-minute LLM calls on a width-2 queue), not to a request cadence — a few-second hint just hot-loops a compliant client into a stream of 429s. A refusal for a spent FAIL-OPEN allowance (below) advises the time left in the hourly allowance window instead, CAPPED at 5x this value — the allowance binds only while the count is unmeasurable, so a cleared blip must not cost a compliant client a whole window |

> **When the gate cannot MEASURE the backlog** (wedged/saturated `AdminRepo` pool, driver
> fault, or a defect in the counting query) it fails OPEN — an innocent tenant must not be
> refused because the count path is degraded — but only for a bounded number of jobs per
> tenant per hour: `max(1, OBAN_INGEST_BACKLOG_MAX / 20)` per web node **per fault lane**,
> which totals one `OBAN_INGEST_BACKLOG_MAX` per hour per tenant across a fleet of up to 10 web
> nodes. **That total is the number to size against — there is no multiplier to apply on top.**
> The divisor is 10 nodes x 2 lanes: pressure faults and non-pressure faults are metered in
> SEPARATE buckets (so a defect in the counting query cannot spend the allowance a genuine pool
> fault is then refused on), and the two lanes SPLIT one threshold's worth rather than each
> getting one. Residual, below a threshold of **20**: the per-lane allowance floors at 1 rather
> than 0 — so the valve cannot fail closed on the first transient blip — and a 10-node fleet can
> then admit up to 20 jobs/hour against a smaller threshold. A request asking for MORE items
> than one window's allowance can never fit it and is refused after a single token. Past that
> allowance the request is refused — `429 ingestion_backlog_exceeded` only when the fault is
> DEMONSTRABLE pool pressure (a wedged/saturated pool, an exit the driver's own pool raised, a
> contention or resource-exhaustion SQLSTATE), otherwise `503 ingestion_gate_unavailable`, which
> asserts nothing about the tenant's backlog. Watch
> `loopctl.ingestion.backlog_gate.failed_open.*` sliced by `outcome` and `error_class`; a
> sustained non-zero rate means the valve is admitting or refusing blind.

> Both accept only a **positive integer**, and unlike the rate-limit knobs above they are
> validated at BOOT (`config/runtime.exs` evaluates them), so a malformed value aborts the
> node LOUD at startup rather than surfacing as per-request 500s on the ingest endpoints.

#### Metrics and scale alerting

| Variable                    | Default | Description |
|-----------------------------|---------|-------------|
| `METRICS_PORT`              | `9568`  | INTERNAL Prometheus listener (never the public `8080` service); scraped over Fly's private 6PN network. **Must stay in lockstep with the `[metrics]` block in `fly.toml`** |
| `METRICS_TENANT_LABEL_CAP`  | `1000`  | Max distinct tenant label values before the per-tenant metric dimension is collapsed — bounds Prometheus cardinality |
| `SCALE_ALERTS_ENABLED`      | `true`  | The OFF switch for a deployment with no alert receiver yet (#376). Only `false` or `0` disables (trimmed, case-insensitive) — any other value, including a typo, leaves alerting ON, so a mistyped value can never silently mean no-alerting. Disabled stops the whole checker: the `ScaleAlerts` child is not started, so nothing is evaluated, logged **or** POSTed (the Prometheus series on `METRICS_PORT` are unaffected and stay the degradation signal). **Set it to `false` whenever `SCALE_ALERT_WEBHOOK_URL` is unset**, or `/health/ready` returns 503 forever |
| `SCALE_ALERT_WEBHOOK_URL`   | -       | **Alerting is opt-in until this is set.** With alerting enabled and no URL, threshold breaches are only logged, never POSTed. Point it at a Slack / PagerDuty / generic webhook. Setting this is a two-part change: the secret AND `SCALE_ALERTS_ENABLED=true` (in `fly.toml`). **Doing only one half is flagged either way** — `/health/ready` reports `checks.scale_alerts: "error"` for both enabled-without-a-URL and URL-set-while-disabled, and names the setting to fix |
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

#### Story verification (GitHub Actions)

| Variable       | Default | Description |
|----------------|---------|-------------|
| `GITHUB_TOKEN` | -       | Bearer token for the CI status/test-result lookups that back independent story verification. Optional: unset, the calls go out unauthenticated, which works for PUBLIC repos until GitHub's 60-requests/hour/IP anonymous limit bites — after that verification reports a `github_api_error` rather than a real CI verdict. Required for a private repo, where unauthenticated lookups 404. Needs only read access to checks. A blank value is treated as unset (it is trimmed), so a templated-but-empty secret degrades to the anonymous path rather than sending an empty bearer that GitHub 401s |

#### CLI client (`loopctl` command, not the server)

Read by `Loopctl.CLI.Config` through an injected `&System.get_env/1`, so each overrides the
matching key in `~/.loopctl/config.json` for that shell only. A blank value is ignored (the
file value stands) rather than blanking the setting.

| Variable          | Default | Description |
|-------------------|---------|-------------|
| `LOOPCTL_SERVER`  | config file, else the CLI's built-in default | Base URL the CLI talks to — point it at a self-hosted deployment |
| `LOOPCTL_API_KEY` | config file value | API key the CLI authenticates with. Prefer this over `loopctl config set api_key` in CI, so the key never lands on disk |
| `LOOPCTL_FORMAT`  | `json`  | Default output format: `json`, `human`, or `csv` |

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
