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

## Runbook: verify clustering before scaling (US-38.3)

`fly scale count > 1` MUST be preceded by verifying BEAM clustering is GREEN.
Without clustering, PubSub is node-local: cross-node cache invalidation still works
(TTL-backstopped, cluster-correct by design — see the scope table above), but the
`SthEnqueuer` cluster singleton and the shared rate limiter only behave correctly
once the nodes actually form a cluster. Running multiple machines UN-clustered is a
silent split-brain, not a hard failure — hence this documented gate + boot WARN
(loopctl never crash-enforces it; a single node must always boot).

**The signal.** `Loopctl.ClusterReadiness.readiness/0` returns a bounded, no-node-name
map: `%{dns_cluster_query_configured, peers, expected_nodes, status}` where `status`
is `:single_node` (clustering not required — `EXPECTED_APP_NODES <= 1` or
`DNS_CLUSTER_QUERY` unset), `:clustered` (configured + expected peers connected), or
`:expected_peers_missing` (configured + `EXPECTED_APP_NODES > 1` but too few peers).
It is also exported as the `loopctl.cluster.peers.count` Prometheus gauge (tagged by
`status`, on the internal `:9568/metrics` port — no node names, no query string).

**Boot WARN.** On prod boot, `Loopctl.ClusterReadiness.warn_if_expected_peers_missing/0`
logs a WARNING when `EXPECTED_APP_NODES > 1` but `Node.list/0` is empty (running
un-clustered). It is a WARN + this runbook, NOT a crash.

**Steps to scale past 1 machine (gated, infra — Mark's hands, out of Epic 38's code scope):**

1. Set the `DNS_CLUSTER_QUERY` Fly secret (the `<app>.internal` 6PN query) — the code
   is already wired (`application.ex`, `runtime.exs`); this story does NOT set it.
2. Set `EXPECTED_APP_NODES` to the target machine count so the readiness signal and
   the `DbCapacity` connection-budget check reflect it.
3. Deploy, then confirm clustering is GREEN: `readiness/0.status == :clustered` (or
   the `loopctl.cluster.peers.count{status="clustered"}` gauge shows the expected
   peers) and NO `expected_peers_missing` boot WARN in the logs.
4. Only then raise `fly scale count`. If the readiness signal is
   `:expected_peers_missing`, clustering is not formed — fix DNS clustering before
   scaling, or you are running node-local PubSub across N machines.

### DNSCluster wiring (verified by test)

`DNSCluster` is a child in `Loopctl.Application`'s supervision tree
(`{DNSCluster, query: Application.get_env(:loopctl, :dns_cluster_query) || :ignore}`),
and `:dns_cluster_query` resolves from the `DNS_CLUSTER_QUERY` env in `runtime.exs`
(unset → `nil` → `:ignore`, so `DNSCluster` runs inert with no process started). This
is asserted by `test/loopctl/cluster_readiness_test.exs` so the wiring can't silently
regress. `DNS_CLUSTER_QUERY` is NOT set by this story.
