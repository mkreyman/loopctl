# Open-issues implementation plan (2026-07-22)

Sequential plan to close the open non-webhook issues: **#428** (Epic 39 spec refinements),
**#451** (US-40.4 advisory file soft-locks), **#464** (US-41.1 prod EXPLAIN + p95 artifact).

Consumed by `/implement-plan` in **plan mode** (WIP=1, one item fully merged before the next).
Items appear in execution order. `mode: plan`, `baseBranch: master`, required checks
`Lint / Test / Security / Dialyzer` (verified against branch protection on `master`).

Ordering rationale: cheapest and lowest-risk first, so the run builds confidence before the
one item that adds a new API surface. Items 1–3 are independent of each other; item 4 touches
`lib/loopctl/coordination.ex` heavily, so it goes last to avoid conflicting with item 1's and
item 2's edits to the same area.

---

## Item 1 — #497: correct the US-39.2 / US-39.3 story specs to match shipped code

**Docs-only. No code change.**

The two refinements were implemented correctly but the story JSONs were never amended, so the
specs still describe the pre-correction behavior. Verified present in code today:

- `conflict_target` mirroring the partial unique index columns **and** its WHERE predicate —
  `lib/loopctl/coordination.ex:1611-1626`
- `GREATEST(inserted_at, updated_at)` for both the delta filter (`:2229`) and the delta ordering
  (`:2287`)

### Scope

1. `docs/user_stories/epic_39_repo_coordination_bus/us_39.2.json` — state the exact
   `conflict_target` requirement (partial-index columns + predicate) and why omitting it raises
   Postgres `42P10` at runtime.
2. `docs/user_stories/epic_39_repo_coordination_bus/us_39.3.json` — state the
   `GREATEST(inserted_at, updated_at)` ordering requirement, **and** record the malformed-`since`
   decision below.

### Malformed `since` — record the as-built decision, do not change behavior

#428 asked for "empty result or 400, never a 500". The shipped behavior
(`normalize_since/1`, `lib/loopctl/coordination.ex:2212-2221`) resolves a malformed, absent, or
date-only value to `nil` — a no-op filter that falls back to the newest page. The hard
requirement (never a 500) **holds**; the "empty result or 400" wording does not.

Keep the current behavior and amend the spec to match it. Rationale: `since` is a delta-read
optimization on a fail-open SessionStart path, and returning the newest page on a bad `since` is
strictly safer for that consumer than a 400 that would blank the TEAM CHANNEL block. This is a
deliberate as-built decision, not an unfixed finding — the spec is what is wrong here.

### Acceptance

- Both JSONs describe the shipped behavior; no code diff in this PR.
- `mix precommit` green.

---

## Item 2 — #498: failure alerting for the US-39.5 channel-post retention sweep

**Code. Reuses the existing ingestion-anomaly operator-alert pattern.**

`Loopctl.Workers.ChannelPostSweeper` (`lib/loopctl/workers/channel_post_sweeper.ex`) only emits
`Logger.info` on a successful non-zero delete. There is no telemetry, no error path, and no
alert. A sweep that fails every run is visible only as Oban retry churn (`max_attempts: 3`) —
exactly the "assumed-healthy" failure #428 asked to close. Retention is a release gate, so a
silently dead sweep means the 30-day window silently stops being enforced.

### Approach — reuse, do not invent

Follow the **dead-man's-switch / freshness detector** pattern already in this repo
(`Loopctl.Workers.IngestionHealthWorker` + `Loopctl.Knowledge.IngestionAnomaly`, loopctl #426).
That module is the reference implementation for: atomic detect-insert, an `alerted` boolean
flipped only after the operator alert + webhook are enqueued (at-least-once), and a recovery
branch that re-fires when a crash left `alerted: false`
(`ingestion_health_worker.ex:440-465`). Mirror that structure rather than a bespoke one.

### Scope

1. Emit `:telemetry` from `ChannelPostSweeper.perform/1` on **both** outcomes — swept (with the
   deleted count) and failed (with the reason). Success-only telemetry cannot distinguish
   "nothing to do" from "never ran".
2. Wrap the delete so a raise/DB error is caught, logged at `error`, emitted as failure
   telemetry, and re-raised so Oban still records the failure and retries.
3. Add the absence-of-success detector: alert when no successful sweep has been observed within
   a bounded staleness window. This is the load-bearing half — a worker that stops being
   scheduled at all produces no failure event to catch.
4. Fire the operator alert through the same path the ingestion anomalies use, with the
   `alerted`-flag ordering so notification is at-least-once.
5. Amend `us_39.5.json` with the alerting acceptance criterion (currently absent — `grep -i alert`
   returns nothing).

### Decision to make during implementation

Whether the detector reuses `IngestionAnomaly` with a new `anomaly_type`
(`@anomaly_types` is `[:capture_silence, :high_reject_rate]`,
`lib/loopctl/knowledge/ingestion_anomaly.ex:60` — extending it needs a migration, cf.
`20260717210001_add_high_reject_rate_anomaly_type.exs`) or a separate lightweight signal.
**Recommendation: extend `IngestionAnomaly` with a `sweep_stalled` type.** It inherits the
whole tested alert/recovery/webhook/API path and the existing operator surface
(`get_ingestion_anomalies`) for free; a parallel mechanism would duplicate it. The migration is
the same shape as the one already in the tree.

### Acceptance

- Sweep failure produces an error log **and** failure telemetry; the job still fails to Oban.
- A sweep that has not succeeded within the staleness window raises an operator alert exactly
  once, and re-fires if a crash left it unalerted.
- Tenant isolation covered where the anomaly row is tenant-scoped.
- `mix precommit` green.

---

## Item 3 — #499: proactive rescan for secrets that slipped past the US-39.1 gate

**Code. Security.**

`Loopctl.Security.SecretDenylist` (`lib/loopctl/security/secret_denylist.ex`, ~11 prefixed
credential patterns) is a **write-time gate only**, self-described best-effort. Remediation
today is purely reactive: someone notices, then deletes the row
(`lib/loopctl/coordination.ex:1054`). There is no rescan anywhere — `grep -rniE "rescan"` over
`lib/` returns nothing.

The amplification risk is specific and real: channel posts carry a 30-day TTL **and** are
injected into every new session's context via the SessionStart TEAM CHANNEL block. A secret that
lands in a post is re-broadcast to every session on that repo for 30 days. A pattern added to
the denylist *after* a post was written never re-examines that post.

### Scope

1. A rescan pass over unexpired `channel_posts` (title, body, refs) using the current
   `SecretDenylist` patterns — so a denylist update retroactively catches what the old pattern
   set missed.
2. Bounded and idempotent, matching `ChannelPostSweeper`'s deliberate non-recursive
   single-batch-per-run design (`channel_post_sweeper.ex` moduledoc) — a rescan must not lock
   the table in one long transaction.
3. On a hit: raise an operator alert (same path as item 2) and quarantine rather than silently
   hard-delete. **Do not auto-delete.** A false positive that silently destroys a coordination
   post is worse than a flagged one; the denylist is prefix-heuristic, not exact.
4. Audit every detection through the existing append-only hash-chained audit log.
5. Amend `us_39.6.json` with the rescan criterion (currently absent).

### Scope note

#428 filed this under `us_39.6`, but 39.6 is *"SessionStart TEAM CHANNEL injection in
claude-config"* — the **consumer**, which lives in the claude-config repo. The gate itself is
**US-39.1** and lives here. Implement server-side against 39.1 and note the correction in the
spec amendment.

### Acceptance

- A post containing a denylisted pattern written *before* the pattern existed is detected on
  rescan and flagged, not deleted.
- Rescan is bounded per run, idempotent, and re-runnable.
- Detections are audited and surfaced to the operator.
- `mix precommit` green.

---

## Item 4 — #451: US-40.4 advisory file soft-locks (loopctl server half)

**Code. New API surface. The largest item — last on purpose.**

Spec: `docs/user_stories/epic_40_coordination_bus_v2/us_40.4.json` (4 ACs).
No implementation exists — every `advisory lock` hit in `lib/` is an unrelated
`pg_advisory_xact_lock` (entity cap, memory quota, token usage). No migration, no MCP tool.

**Advisory, not exclusive.** Two sessions may hold a lock on the same file simultaneously; the
lock informs, it never blocks. This is the opposite of the `channel_claims` handoff claim, where
the first writer wins and the loser gets a 409.

### Confirmed build-on-what-exists

Per AC-40.4.1 this needs **no new table** — it is a keyed channel post with key
`claim:<target>`, `refs.file = target`, and a short TTL. Verified: `refs` has a **free** `type`
field with no allowlist (`lib/loopctl/coordination/refs_list.ex:4,11`), so `type: "file"`
requires no change.

### The two real gaps

1. **Short, server-clamped TTL.** `expires_at` is currently hardcoded to `now + 30 days`
   (`default_expires_at()`, `lib/loopctl/coordination.ex:196,427`). AC-40.4.1 needs an optional
   `ttl_seconds` on the write path, server-clamped to roughly 1..60 minutes. Clamp server-side —
   an unclamped client TTL lets a dead session wedge a file for the full retention window.
2. **Delete-by-slot-key.** `delete_post/5` (`coordination.ex:1099`) deletes by post id only.
   AC-40.4.3 needs delete by the hardened 5-column slot key
   `(tenant, project, agent_id, session, key)` so a caller can release its own lock without
   knowing the post id.

### MCP tool naming — collision, must be resolved

AC-40.4.4 says "claim/release are exposed as MCP tools", but `channel_claim` and
`channel_release` are **already taken** by the exactly-once handoff claim
(`mcp-server/README.md:170-171`). Reusing those names would conflate two opposite semantics —
advisory-and-shareable vs exclusive-first-wins — in the one place an agent picks between them.

**Recommendation: `channel_lock` / `channel_unlock`.** Distinct from the claim verbs, and "lock"
carries the advisory-hint reading in a shared-editing context. Document in both tool descriptions
that the lock is advisory and never blocks an edit, and cross-reference the claim tools.

### Acceptance

- `channel_lock` posts a keyed slot with a server-clamped short TTL; a second session can lock
  the same file and is not blocked (advisory).
- `channel_unlock` deletes only the caller's own lock, via the slot key; another session's or
  another tenant's lock returns a byte-identical 404 (match `channel_release`'s owner-scoping).
- Expired locks stop surfacing without relying on the retention sweep.
- `channel_recent` surfaces active locks distinctly enough for a client to render them.
- Tenant isolation test.
- `mcp-server/README.md` updated (it is the source of truth for the tool list).
- `mix precommit` green.

---

# Out of scope for this run

These are **not** `/implement-plan` items. Do not let the planner pick them up.

## #451 second half — claude-config TEAM CHANNEL rendering (AC-40.4.2)

AC-40.4.2 requires the SessionStart TEAM CHANNEL block to surface active locks
(`claimed: <file> by <agent/host>, <age>`). That block lives in **claude-config**
(`hooks/session-start.sh`), a different repo, and ships on claude-config's own delivery loop.

It depends on item 4's server API, so it is a **separate run against the claude-config repo
after item 4 merges**. Item 4 is independently useful without it (the MCP tools work; only the
passive at-session-start surfacing is missing).

## #464 — US-41.1 production EXPLAIN + p95 artifact

**Cannot be implemented. Not a code change.** It is a production observation, and it is
already substantively complete — two artifact comments are posted on the issue:

- Plan shape on the real 83.6k corpus: **PASS** (`article_embeddings_hnsw_dim_1536_idx`, no Seq
  Scan reaching the vector relation). Both EXPLAINs attached verbatim.
- Backfill: 83,605 rows, gap 0, drift 0.
- Latency: **no regression** — the side-table path benchmarks 2–3× faster (p95 314 ms vs
  1442 ms); the early 5–10 s outliers were a cold-cache transient that has since cleared.

**One step remains, blocked on elapsed time — not on work.** The formal 24h post-cutover p95
window closes `2026-07-23T08:43Z` (tomorrow). One PromQL readout against Fly managed Prometheus,
anchored at the after-window end:

```
GET /prometheus/ecommerce-friendly/api/v1/query
  time=2026-07-23T08:43:35Z
  query=histogram_quantile(0.95, sum by (le) (rate(loopctl_heavy_read_repo_query_duration_bucket{endpoint="semantic_search"}[24h])))
```

Pass = within 20% of the 229.75 ms baseline, or lower. Read it alongside p50 and the bucket
distribution, not in isolation — this instance serves ~2 semantic searches/hour, so a single
cold-resume query can inflate a sparse-window p95.

Requires **fly auth**, which per the port-registry playbook means **mac-mini**. This machine
(beelink) cannot produce it. Then close #464. If a genuine regression shows, it is an incident
to roll back via AC-41.1.8(iii), not a finding to file.

---

---

# Run configuration (already applied)

`#428` was split into three child issues — **#497** (Item 1), **#498** (Item 2), **#499**
(Item 3) — because `/implement-plan` plan mode maps one item to one GitHub issue and closes it
on merge; three items pointing at #428 would have closed it after the first merge and violated
one-logical-change-per-PR. #428 stays open as the tracking parent and is closed by hand once all
three children merge. Item 4 maps directly to **#451**.

`.claude/implement-plan.run.json` is set to `mode: plan` with `source` pointing at this document.
Required checks (`Lint / Test / Security / Dialyzer`) verified against `master` branch
protection. `Retrieval Eval` runs on every PR but is not a required check, so the merge gate does
not wait on it.
