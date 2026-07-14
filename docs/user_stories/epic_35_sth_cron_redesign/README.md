# Epic 35 — STH & Cron Fleet-Cost Redesign

Remediation of GitHub issue **#350** (roadmap Epic 3, tracked **#355**) — the
per-minute Signed-Tree-Head machinery contains a self-inflicted critical that
worsens quadratically as each tenant's audit chain grows.

## Scope reconciliation (verified against `master` before authoring)

Issue #350 predates recent work; **3 of its 6 findings are already done** and are
**excluded**:

| #350 finding | Status | Evidence |
|--------------|--------|----------|
| Fanout uses N single-row inserts instead of `insert_all` | ✅ done | US-32.5 — `compute_sth_worker.ex:59-68` uses `Oban.insert_all/1`, chunked at 5000 |
| Zero-jitter thundering herd at the `:00` tick | ✅ done (jitter part) | US-32.5 — `schedule_in: jitter(tenant_id)`, deterministic `phash2` over a 56s window (`compute_sth_worker.ex:45,57,113`) |
| `RevokeExpiredDispatchesWorker` query can't use its index | ✅ done | US-32.1 — `20260713000000_add_dispatches_expires_at_active_index.exs` adds `CREATE INDEX CONCURRENTLY … ON dispatches (expires_at) WHERE revoked_at IS NULL`; worker test asserts Index Scan (not Seq Scan) |
| `dispatches` missing partial index `(expires_at) WHERE revoked_at IS NULL` | ✅ done | Same migration — exact predicate match, not a different one |

The **genuinely-remaining** work is the three findings the audit rated as the
actual fleet-cost drivers:

| #350 finding | Status | Story |
|--------------|--------|-------|
| `ComputeSthWorker` rebuilds the **entire** per-tenant Merkle tree on every append (O(chain) per active tenant, forever) | ❌ open (guarded only by `sth_needed?/1` skip-if-unchanged) | **US-35.1** |
| STH is **poll-based** per-tenant-per-minute rather than event-driven; the fanout does not gate to tenants with new activity (N idle-tenant jobs enqueued every minute) | ❌ open (`ChainPubSub` broadcasts on append but nothing consumes it to enqueue STH) | **US-35.2** |
| The blanket per-minute all-tenants cron poll should become a low-frequency safety sweep once the event path exists | ❌ open (`config/config.exs:331` = `"* * * * *"`) | **US-35.3** |

## Stories

| Story | Title | Depends |
|-------|-------|---------|
| US-35.1 | Incremental STH: checkpointed Merkle peaks, folding only entries above the last STH — **root byte-identical** to the current construction | — |
| US-35.2 | Event-driven STH: audit-append firehose topic + supervised debounce-enqueuer; cron becomes the fallback, not the only path | — |
| US-35.3 | Reduce the all-tenants cron from every-minute to a low-frequency, config-driven safety sweep (primary path is now US-35.2) | US-35.2 |

## Non-negotiable constraints (system is LIVE, audit chain is security-critical)

- **US-35.1 is the highest-risk change in the whole roadmap.** The current
  Merkle construction is **Bitcoin-style** (`merkle_tree/2`,
  `audit_chain.ex:273-285` — pad odd levels by duplicating the last element),
  **not** RFC-6962. A naive Merkle-Mountain-Range frontier produces a
  **different** root. The incremental path MUST emit a **byte-identical**
  `merkle_root` to `compute_merkle_root/1` for **every** chain length, or:
  (a) already-signed historical STHs and external witness caches stop
  verifying, and (b) a divergent STH can trip the L6 byzantine/custody-halt
  path. The safety net is a **property test** using the existing
  `merkle_tree/2` as the reference oracle over random append counts (including
  odd/even/power-of-2 boundaries and single-leaf). `merkle_tree/2` stays the
  source of truth; the checkpoint is a cache that must never change the answer.
- The one migration (US-35.1's checkpoint table) is an **additive
  `CREATE TABLE`** — it does **not** touch the hot `audit_log_entries` /
  `audit_signed_tree_heads` tables and blocks no writes.
- US-35.2 adds a **firehose broadcast alongside** the existing per-tenant
  `audit_chain:<id>` topic — the per-tenant topic and its `{:audit_chain_entry, …}`
  / `{:sth_updated, …}` messages are **unchanged** so external agent witness
  caches are unaffected.
- Debounce/coalescing must be **Basic-Engine-safe**: the event path enqueues via
  single `Oban.insert/2` (where `unique` *is* honored, unlike the `insert_all`
  fanout), with a short `schedule_in` so an append burst collapses to one
  compute. No Smart-Engine assumption.
- US-35.3 only **lowers the safety-sweep frequency** — the `sth_needed?/1` gate
  plus the sweep still guarantee eventual STH for any tenant the event path
  missed. It is independently revertible (config only).
- Every merge is smoke-gated with a `knowledge_count` / STH-endpoint health check
  either side. Every new query runs on a read path (`HeavyRead` / short
  `SET LOCAL statement_timeout`, per-query — never a startup `:parameter`,
  pgbouncer-safe).
- **This epic's review MUST include the security-adversary lens** (root
  divergence, replay, byzantine-halt) on US-35.1 — not optional.
