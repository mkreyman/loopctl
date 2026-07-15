# Epic 38 — Horizontal Scaling Readiness (CODE-ONLY)

Remediation of GitHub issue **#353** (roadmap Epic 6, tracked **#355**) — making
loopctl multi-node-**safe in code** so `fly scale count > 1` is a config/secret
flip when the time comes. The last roadmap epic.

## Decision: code-readiness only, NO infra (Mark, 2026-07-15)

#353 mixes code with infrastructure. Per Mark's decision this epic is
**CODE-ONLY** — build the multi-node-safe code paths, **all flag/env-gated to
today's single-node behavior**, with **zero infra provisioning and zero spend**.
It is "not urgent at current node count" (the issue's own words). The infra
actions are explicitly **OUT OF SCOPE**, left as documented, gated steps for when
Mark decides to scale:

- Provisioning a Fly MPG read replica.
- Setting the `DNS_CLUSTER_QUERY` Fly secret (code is already wired).
- Raising machine `count` past the ~3-node ceiling / upgrading the MPG plan.
- Any real pgbouncer connection-multiplexing tuning.

## Scope reconciliation (verified against `master` before authoring)

| #353 finding | Status | Evidence |
|--------------|--------|----------|
| `DNS_CLUSTER_QUERY` / BEAM clustering code wiring | ✅ done | Epic 32 — `DNSCluster` in `application.ex:28`, env at `runtime.exs:345` (unset → `:ignore`). Needs only the Fly secret (infra, out of scope). |
| HeavyRead dedicated isolated pool + `DbCapacity` budget | ✅ done | Epic 27/33 — but shares the primary DSN (`runtime.exs:299-305`); no replica DSN |
| pgbouncer-safe params (`SET LOCAL`, `prepare: :unnamed`) | ✅ done + guarded | Epic 27/33 — `pgbouncer_startup_params_test.exs` |
| **PubSub cross-node cache invalidation** (SettingsCache, ApiKeyCache) | ✅ done — cluster-correct BY DESIGN | Epic 32/33 — `broadcast_from` + node-local ETS bust + TTL backstop. **Do NOT re-scope.** |
| PubSub adapter is cross-node | ✅ done | default `Phoenix.PubSub.PG2` (`:pg`) — fans out once clustered |
| Actual replica / plan / scale-count / secret | ⏸ infra — OUT OF SCOPE | Mark's hands; documented gated steps |

The **genuinely-remaining CODE-ONLY** work:

| Finding | Status | Story |
|---------|--------|-------|
| Rate limiter is per-node ETS → a global limit becomes `limit × N` across nodes (defeats the DB-pool protection it exists for) | ❌ open | **US-38.2** |
| `SthEnqueuer` is a node-local singleton → N nodes each enqueue off the same firehose (duplicate STH work) | ❌ open | **US-38.3** |
| No clustering verification / health gate; no DNSCluster test | ❌ open | **US-38.3** |
| `HeavyReadRepo` hardcoded to the primary DSN; no `REPLICA_DATABASE_URL` plumbing; `DbCapacity` has no replica dimension | ❌ open | **US-38.1** |
| HNSW indexes use pgvector defaults (`m=16, ef_construction=64`), untuned; `memories.embedding` carries a dual HNSW index | ❌ open (review) | **US-38.4** |

## Stories

| Story | Title | Depends |
|-------|-------|---------|
| US-38.1 | Replica-ready read config: `REPLICA_DATABASE_URL` plumbing for HeavyReadRepo (defaults to primary when unset) + `DbCapacity` replica dimension | — |
| US-38.2 | Cluster-global rate limiter: a shared **Postgres**-backed `RateLimiter` behind the existing behaviour (default node-local ETS), covering the web limiter *and* `Provider.Admission` | — |
| US-38.3 | Cluster-safe `SthEnqueuer` singleton + clustering-readiness verification/health gate + DNSCluster wiring test | — |
| US-38.4 | HNSW `m`/`ef_construction` tuning + `memories.embedding` dual-index justification review | — |

## Non-negotiable constraints (system is LIVE; single-node today)

- **DEFAULT = today's behavior, exactly.** Every new capability (replica DSN,
  shared limiter, singleton mode) is **flag/env-gated and defaults OFF** so a
  single-node deploy behaves byte-for-byte as it does now. Enabling any of them
  is a deliberate future op, tested here but not turned on.
- **No infra, no spend, no scaling.** This epic provisions nothing and does NOT
  set `DNS_CLUSTER_QUERY`, does NOT raise `scale count`, does NOT change the MPG
  plan. Those stay documented gated steps. **Never set a secret to a doc
  placeholder** (epic_35 `STH_SWEEP_CRON` lesson).
- **Correctness on both sides of every flag.** The shared limiter (US-38.2) must
  give identical results to the ETS path for a single node, and cluster-global
  results only when enabled; the replica config (US-38.1) must be
  read-only-safe (never route a write to a replica) and fall back to primary.
- Any HNSW/index migration (US-38.4) is **online** (`CONCURRENTLY`,
  `@disable_ddl_transaction`) on the hot `articles`/`memories` tables and must
  not degrade recall (a recall test either side).
- Env-driven knobs via `SystemConfig`/config-based DI; assert outcome classes,
  not timing (async-suite flake lesson); watch master **Deploy + Post-deploy
  Smoke** to green (runtime.exs env changes only fail at release boot).
