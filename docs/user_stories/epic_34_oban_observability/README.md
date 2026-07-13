# Epic 34 — Oban Resilience, Retention & Observability

Remediation of GitHub issue **#349** (roadmap Epic 2, tracked **#355**) — the alerting/observability that would have made every other incident non-silent.

## Scope reconciliation (verified against `master` before authoring)

Issue #349 predates recent work; three items are already done and are **excluded**:

| #349 item | Status | Evidence |
|-----------|--------|----------|
| Oban Lifeline | ✅ done | `config/config.exs:325` (via #323) |
| Oban Pruner | ✅ done | `config/config.exs:328` (via #323) |
| Fail-loud on missing `SCALE_ALERT_WEBHOOK_URL` | ✅ done | US-32.4 (#361) — readiness guard in `health_check/default.ex` + `scale_alerts.ex:206-215` |

US-33.1 (#366) also already exports per-pool `queue_time` **telemetry** — US-34.3 adds the missing **alert** on it.

## Stories (the genuinely-remaining work)

| Story | Title | Depends |
|-------|-------|---------|
| US-34.1 | Oban queue/state + `:executing` orphan gauges; add Reindexer, pin Stager | — |
| US-34.2 | Surface Oban orphan/queue health in the `/health` degraded path | US-34.1 |
| US-34.3 | 3 ScaleAlerts signals: Repo queue_time p95, discard/retry rate, provider-error rate | US-34.1 |
| US-34.4 | Wire emitted-but-dead telemetry (`llm.blocked`, `embedding.skipped_no_key`, `index_health.invalid`, …) into metrics | — |
| US-34.5 | Harden alert delivery: retry/backoff (via Oban) + periodic re-notify while breached | — |
| US-34.6 | Bound `GET /knowledge/ingestion-jobs` COUNT: online index + HeavyRead + statement_timeout | — |

## Non-negotiable constraints (system is LIVE)

- Nearly all stories are **additive observability** — no job semantics change.
- The one migration (US-34.6) is **online** (`CONCURRENTLY`, `@disable_ddl_transaction`) on the hot `oban_jobs` table.
- All new metrics use **bounded tags** (no tenant/args/free-text) — cardinality is the multi-tenant risk; every metric story tests it.
- Every merge is smoke-gated with a KB-health check either side; `statement_timeout` stays a per-query `SET LOCAL` (pgbouncer-safe).
