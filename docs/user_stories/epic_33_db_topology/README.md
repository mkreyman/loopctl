# Epic 33 — DB Connection Topology & AdminRepo Hot Path

Remediation of GitHub issue **#348** (roadmap Epic 1, tracked **#355**) — the do-first root cause of the "degraded under one heavy agent" incident.

## The problem (verified against live code)

Every authenticated request runs **5 AdminRepo queries incl. 2 writes** on a **3-connection** BYPASSRLS pool, while the 10-connection RLS `Repo` pool sits nearly idle:

1. `SELECT api_keys` by key_hash + `preload: [:tenant]` (`auth.ex:83`)
2. `UPDATE api_keys.last_used_at` (`auth.ex:197`) — **write**
3. `SELECT agents` (`agents.ex:154`)
4. `UPDATE agents.last_seen_at` (`agents.ex:161`) — **write**
5. `SELECT tenants` for custody halt (`tenants.ex:680`) — **redundant**, tenant already loaded by #1

Plus a token-report N+1 (`get_scope_spend` per budget) on the same pool.

## Decomposition — safe wins first, blanket reroute avoided

Grounding (see the DB-topology map) showed the roadmap's headline "route all OLTP through the RLS Repo" is **high-risk on a live system and likely unnecessary**: the hot-path pressure is relieved far more safely by targeted fixes. So the blanket reroute is replaced by a flag-guarded, measured **pilot** (US-33.7).

| Story | Title | Risk | #348 aspect | Depends |
|-------|-------|------|-------------|---------|
| US-33.1 | Per-pool `queue_time` telemetry (Repo + AdminRepo) | Low (additive) | measure first | — |
| US-33.2 | Drop redundant tenant re-SELECT (#5) | Low (pure win) | fewer hot-path queries | — |
| US-33.3 | ETS cache for api-key resolution (#1) | **Med — security** | remove hot-path SELECT | — |
| US-33.4 | Debounce last_seen/last_used writes (#2,#4) | Med | remove hot-path writes | — |
| US-33.5 | Batch token-spend N+1 | Med | reduce AdminRepo fan-out | — |
| US-33.6 | Rebalance pool sizes + DbCapacity | Low-Med (config) | re-size to where load lands | US-33.1 |
| US-33.7 | Flag-guarded RLS-reroute **pilot** (1 read path) | **High** | validate reroute safely | US-33.1 |

## Non-negotiable constraints (system is LIVE with agents doing KB retrieval)

- **US-33.3 is a security boundary:** a revoked/rotated key must NEVER authenticate from stale cache — invalidation on every revoke/rotate path + bounded TTL are release gates.
- **US-33.7 is a security boundary:** RLS-parity + tenant-isolation + fail-closed tests are release gates; the flag stays OFF in prod unless the prod Repo role is verified to lack BYPASSRLS.
- Every merge auto-deploys behind the **smoke gate** (DB+Oban liveness, KB/retrieval/memory/auth hard-checked) with a KB-health check either side. Config/flag changes default to current behavior.
- No migration here is expected; any added index is online (`CONCURRENTLY`).
