# Runbook: Post-Deploy Smoke & Regression Safety Net

## Purpose

loopctl at <https://loopctl.com> is LIVE and serving **knowledge-base (KB)
retrieval** to agents continuously. This safety net catches regressions right
after each deploy **without ever mutating live state** — every check is
read-only. If it goes red, the deploy is suspect and you roll back.

Two layers:

1. **`scripts/smoke.sh`** — fast, read-only curl+jq probes against the live
   deployment. Runs automatically in CI after each master deploy, and by hand.
2. **`test/e2e/*` ExUnit journeys** — full cross-context journeys (retrieval,
   chain-of-custody, agent-memory round-trip) against the test DB. These now run
   in CI as a step in the `test` job (`mix test --only e2e`), so they **gate
   deploy** (`deploy` needs `test`) — a broken journey blocks the release. Also
   runnable locally with `mix test.e2e`.

---

## 1. What the smoke covers (and why)

`scripts/smoke.sh` runs these checks. Pure-DB checks use the default 5000 ms
budget (`SMOKE_MAX_MS`); the two checks that generate an on-the-fly query
embedding (an outbound LLM call) get a wider 8000 ms budget (`SMOKE_EMBED_MAX_MS`).
Total wall time stays well under 30 s.

| # | Check | Asserts | Budget | Why |
|---|-------|---------|--------|-----|
| 1 | `GET /health` | 200 **and** `.checks.database == "ok"`; Oban-only degradation is a WARN (pass) | 5 s | App up + DB healthy (liveness only — never depooled by the scale-alerts config-guard) |
| 1.5 | `GET /health/ready` | 200, `.ready == true` (falls back to `.status=="ok"` for an implementation that omits `ready`) | 5 s | **US-32.4 readiness gate**: fails loud (hard RED, not a warn) if scale alerts are enabled but `SCALE_ALERT_WEBHOOK_URL` is unset — the automated consumer of the readiness signal so the misconfig is caught at deploy time instead of during the incident it should have warned about |
| 2 | `GET /api/v1/knowledge/count` (authed) | 200, `.count` int > 1000 | 5 s | KB not wiped (prod baseline ~83k) |
| 3a | `GET /api/v1/knowledge/search?q=elixir&mode=keyword&limit=3` (authed) | 200, `.data` non-empty | 5 s | **Keyword retrieval floor** (deterministic DB path, no embedding) |
| 3b | `GET /api/v1/knowledge/search?q=elixir&limit=3` (authed, combined) | 200, `.data` non-empty **and** `.meta.fallback != true` | 8 s | **Semantic retrieval healthy** — fails if the embedding provider is down (combined silently keyword-falls-back otherwise) |
| 4 | `GET /api/v1/knowledge/stats` (authed) | 200, `.total` numeric | 5 s | Stats/aggregation path alive |
| 5 | `POST /api/v1/memory/recall` (authed, `{"query":"smoke","limit":1}`) | 200, `.data` array + `.meta` | 8 s | Epic-28 agent-memory recall alive (recall is a READ; empty result is a PASS) |
| 6 | `GET /api/v1/knowledge/search?q=x` (NO key) | 401 | 5 s | Auth boundary intact |

Exit code is non-zero if ANY check fails. A WARN (⚠) does not fail the run.

### Reading a RED result

- **3b RED but 3a green** — keyword retrieval works, semantic doesn't. This is an
  **embedding-provider / tenant-BYO-key** problem (the embedding API is down, rate
  limited, or the tenant's LLM key is missing/invalid), NOT necessarily a code
  regression. Check the embedding provider and the smoke tenant's LLM config
  before rolling back; a code rollback won't fix a dead provider.
- **1 WARN (Oban degraded, DB ok)** — `/health` returns `degraded` (HTTP 503) if
  EITHER the DB or the Oban `:default` queue check fails. A transient Oban blip
  with a healthy DB + KB is **not** a rollback trigger, so the script warns and
  passes. Only a DB failure or a non-200 is a hard FAIL on check 1.
- **1.5 RED (`/health/ready` 503 or `.ready == false`)** — this is a **config**
  problem, not a code regression: `:scale_alerts_enabled` is true but
  `SCALE_ALERT_WEBHOOK_URL` is unset (or blank) on the deployed release. Fix is
  to set the Fly secret/env var, not to roll back the code. `.reasons.scale_alerts`
  in the response body names the missing env var (never a value).
- **2 RED (count ≤ 1000)** — see the visibility invariant below; a wiped corpus or
  a changed smoke-key tenant both show up here.

### Count-threshold visibility invariant

Checks 2 and 3 rely on this: `LOOPCTL_SMOKE_KEY` is an **agent-role key in the
tenant that owns the shared knowledge corpus**, and corpus articles are
`shared`-visibility (metadata `visibility` defaults to `"shared"`, which
`Visibility.scope_opts` + `Loopctl.Knowledge.maybe_filter_by_visibility` make
visible to agent callers). So `count > 1000` and non-empty search are provably
satisfied for that key. **If the smoke key's tenant or the corpus visibility ever
changes, re-derive these thresholds** — otherwise check 2/3 could false-RED on a
perfectly healthy deploy.

### Witness header (important)

Every `/api/v1` authenticated request passes through `ValidateWitnessHeader`,
which is **enforced in prod** (disabled only in test). Without an
`X-Loopctl-Last-Known-STH` header, authed checks would fail with `412
witness_header_missing`. `smoke.sh` handles this automatically: it first
**primes** the current STH via the one-time bootstrap-grace response header
(`X-Loopctl-STH-Bootstrap: true` → `x-loopctl-current-sth`) and then sends it on
every authed check. This priming has no side effect (the plug halts before any
operation runs).

---

## 2. How it runs automatically in CI

Two things run in CI, at two different stages:

**Pre-deploy gate — the e2e journeys.** The `test` job runs `mix test --only e2e`
right after the normal suite, reusing the provisioned Postgres. Because `deploy`
needs `test`, a broken journey (retrieval, custody, or memory round-trip) **blocks
the deploy**. The default `mix test` still excludes `:e2e`, so local dev stays fast.

**Post-deploy detector — the smoke.** `.github/workflows/ci.yml` has a `smoke` job:

- `needs: [deploy]` — runs **after** the Fly deploy, so it validates the
  freshly-deployed release, not the old one.
- `if: github.event_name == 'push' && github.ref == 'refs/heads/master'` — only
  on a real master deploy (never PRs or the nightly schedule).
- Installs `jq`, then runs `bash scripts/smoke.sh` with `BASE_URL` and
  `LOOPCTL_SMOKE_KEY` supplied via the step's `env:` block (secret kept off the
  `run:` line).

It does **not gate** anything (the deploy already happened) — it is a
**detector**. A smoke failure turns the run RED so the operator knows to roll
back. `LOOPCTL_SMOKE_KEY` must be a **low-privilege read key** (an `agent`-role
key is sufficient — the script only reads).

**Cost note:** each master deploy spends ~2 embedding tokens (the semantic-search
check 3b + the memory-recall check 5 each generate one query embedding). This is
intended and negligible.

---

## 3. How to run it manually

### CLI

```bash
LOOPCTL_SMOKE_KEY=<low-priv read key> bash scripts/smoke.sh
# Optional overrides:
BASE_URL=https://loopctl.com SMOKE_MAX_MS=5000 SMOKE_EMBED_MAX_MS=8000 \
  LOOPCTL_SMOKE_KEY=... bash scripts/smoke.sh
```

Each check prints `✓ name (Nms)`, `⚠ name — detail` (warn, still passes), or
`✗ name — detail`. Non-zero exit ⇒ investigate.

### Equivalent MCP-tool checklist (operator / agent, read-only)

If you have the loopctl MCP tools wired, you can reproduce the smoke by hand
without curl — all read-only:

1. `mcp__loopctl__knowledge_search({ q: "elixir", limit: 3 })` → expect a
   non-empty result set (retrieval works).
2. `knowledge count` — via `knowledge_search` in list mode or
   `knowledge_stats` — expect a large populated corpus (thousands of articles).
3. `mcp__loopctl__list_projects()` → expect your projects to enumerate
   (auth + tenant scope intact).
4. `mcp__loopctl__memory_recall({ query: "smoke", limit: 1 })` → expect a 200-shaped
   result (an empty list is fine; you are proving the endpoint is alive).

An empty result on (4) is a PASS. A hard error, timeout, or auth failure on any
of these is a FAIL — treat it like a red smoke run.

---

## 4. Latency budgets

- Per-request budget: **5000 ms** (`SMOKE_MAX_MS`) for the pure-DB checks
  (health, count, keyword floor, stats, auth-negative). A check that exceeds its
  budget fails even on a 200 — a slow crown-jewel path is a regression signal.
- Embedding budget: **8000 ms** (`SMOKE_EMBED_MAX_MS`) for the two checks that do
  an on-the-fly query embedding (semantic search 3b + memory recall 5), since an
  outbound LLM call is ~1–3 s.
- Total smoke wall time: **well under 30 s** on the happy path. The `/health`
  poll retries up to ~10× with capped (≤3 s) backoff so a smoke run kicked the
  instant a deploy finishes waits for the new release to accept traffic before
  the real assertions.

---

## 5. ROLLBACK procedure (Fly.io, app `loopctl`)

If smoke is red after a deploy, roll back to the previous known-good release:

```bash
# List releases (most recent first) — note the previous version/image ref
fly releases -a loopctl

# Preferred: roll back to the immediately previous release (if your flyctl has it)
fly releases rollback -a loopctl

# Or roll back to a specific version
fly releases rollback <version> -a loopctl

# Fallback (older flyctl without `releases rollback`): redeploy the previous image
#   grab the previous image ref from `fly releases` / `fly image show -a loopctl`
fly deploy --image <previous-image-ref> -a loopctl
```

After rollback, re-run the smoke against prod to confirm green:

```bash
LOOPCTL_SMOKE_KEY=... bash scripts/smoke.sh
```

Then open an issue capturing the failing check and the bad release, and fix
forward on a branch through the normal review-gated loop.

---

## 6. Expand–contract migration rule (do NOT skip)

Fly does a **rolling** deploy: for a window, the OLD and NEW releases run
concurrently and BOTH serve live KB-retrieval traffic. Every migration in these
epics **must be backward-compatible** so an in-flight request against the old
release never breaks, and so a rollback is always safe:

- **Expand first.** Add new tables and **nullable** columns; add new indexes
  `CONCURRENTLY`. The old release must keep working against the new schema.
- **Never** drop or rename a column/table a still-running release reads, and
  never add a `NOT NULL` (without a default) or a tightening `CHECK` in the same
  deploy that starts writing it.
- **Contract later**, in a SEPARATE deploy, only after every running release no
  longer references the old shape.
- Backfills run as their own step (e.g. an Oban job / data migration), decoupled
  from the schema change, so a long backfill can't hold a lock across the deploy.

Rule of thumb: **a rollback to the previous release must succeed against the
current database at all times.** If a migration would break the old release,
it's not expand–contract — split it.
