# Design Brief: Repo Coordination Bus (the third memory plane)

**Status:** draft / proposal · **Author:** derived with Mark, 2026-07-17
**Related:** `docs/agent-memory.md` (#411 memory substrate), `docs/knowledge-hybrid-retrieval.md`, owner decision #331 (KB content surface is fully agent-usable)

---

## 1. Problem

When Mark works the **same repo from more than one machine and/or more than one session**, the sessions can't talk to each other. Today that coordination happens by hand — literally copy-pasting one session's finding into another (e.g. relaying a beelink session's note about a hook to a blockit session). There is no shared, transient, repo-scoped place for sessions to leave each other messages, hand off work, or avoid stepping on the same files.

The stopgap that half-covers this — **memory-keeper** — is a **local SQLite MCP server, one DB per machine**. So it structurally *cannot* bridge machines: context saved on mac-mini is invisible on beelink.

### 1.1 The fragmentation is real and measured (fleet audit, 2026-07-17)

memory-keeper `context_items`, per project × machine (richest DB on each: `~/mcp-data/memory-keeper/context.db`):

| Project | blockit | mac-mini | beelink | total |
|---|---|---|---|---|
| home_care_billing | 444 | 3163 | 679 | **4,286** |
| loopctl | 50 | 332 | 94 | 476 |
| cron_books | 0 | 504 | 38 | 542 |
| claude-config | ~6 | 6 | 5 | ~17 |

**home_care_billing's memory is 4,286 items split three ways, none shared** — and beelink's slice is active *today* while mac-mini's spans Dec–Jul. Working HCB from beelink, you cannot see 3,163 items of mac-mini context. One project, three disconnected memories, for seven months.

### 1.2 What is actually used (so we don't rebuild what nobody touches)

Feature-table row counts across all three machines:

- **Used:** `context_items` (key/value working state, *mostly uncategorized*), `checkpoints` (build→ship handoff: 64 / 73 / 3), `vector_embeddings` (auto, ≈ item count → semantic search).
- **Zero rows on every machine:** `journal_entries`, `entities`, `relations`, `compressed_context`, `observations`, `agent_tasks`. `file_cache` = 0 / 0 / 6.

The real footprint is **3 of ~15 feature areas.** RGN's own `.claude/SETUP.md` already demotes memory-keeper to *"a mirror, not the source of truth"* (files in `.claude/checkpoints/` + `.claude/state/*.md` are primary), and names the only thing that degrades without it: *"cross-session history and search."*

---

## 2. The model: a third memory plane

loopctl already hosts two memory planes. This adds the missing third:

| Plane | Scope | Lifetime | Purpose | Status |
|---|---|---|---|---|
| **Knowledge** | tenant-wide, curated | durable (months+) | reusable lessons | exists |
| **Memory** | one agent, private | working state | *my* accumulated context | exists (`memory_*`) |
| **Channel / Bus** | one **repo/project**, shared | **transient** (≤30d) | situational awareness *between* concurrent/sequential sessions | **new** |

The bus is not "Slack for agents." It is a **project-scoped coordination log**: append-only, attributed, typed, read at the moments an agent can act on it.

---

## 3. Design

### 3.1 Channel = a repo
A channel is a `project_id` (a work project, or the KB scope created via `create_kb_scope` for repos with no work project). Every session on `claude-config` shares one channel. Tenant-isolated by RLS, exactly like knowledge/memory.

### 3.2 Message = one simple, attributed post (no type taxonomy)
Deliberately minimal (owner decision, 2026-07-17: *"I wouldn't bother with message types and their specific retentions. It's really that simple."*). A post carries, server-stamped: `agent_id` (from the key — tamper-evident, never from the body), `host`, `session_id`, `created_at`, `project_id`; plus a free-text `body`, an **optional** `key`, and **optional** structured `refs` (`{file, pr, branch, commit}`).

- **No `kind` enum.** A post is just a message on the repo's channel. Whether it's a heads-up, a status, a hand-off, or a working-state note is expressed in the body/refs, not a required taxonomy — the fleet audit showed the 6-category taxonomy in memory-keeper was barely used, so we don't reintroduce one.
  - **Reaffirmed (Epic 40, 2026-07-18):** the design panel floated reintroducing an indexed read-routing `kind` column; the owner declined — message types stay out. Discovery/routing is done by the stable `handoff:` / `claim:` **key prefix** (index-served via a partial index), not a type column. Story 40.A4 was cut.
- **Amended (US-454, 2026-07-20, issue #454):** three handoff-reliability fixes landed after a real cross-machine handoff silently degraded to "human must relay it":
  1. **Keyed path works without `CLAUDE_SESSION_ID`.** The MCP proxy falls back to a process-lifetime session id; the server mints a one-off surrogate (`srvgen-…`) for clients that still send none, and *derives* a `handoff:<anchor>` key from a keyless body that announces one. The write response surfaces both rescues (`meta.key_source` / `meta.session_id_source`) so degradation is loud at post time, not discovered by the receiver.
  2. **Discovery is see-everything by default.** `channel_handoffs` no longer filters by addressing — `to_host`/`to_capability` only drive a per-row `directed_to_me` label (owner requirement: addressing is a hint, never a filter, so a mistyped/offline addressee never strands work). `only_mine: true` is the opt-in narrow view.
  3. **Supersession is a terminal state.** `channel_posts.superseded_by` (self-FK) marks a retired post with its successor's id, set in the same transaction as the successor's write (`supersedes` param, author or `>= :user` only). Discovery excludes superseded posts; the history read marks them.
- **`key` is optional and enables upsert.** Posting with the same `(project_id, key)` overwrites — that covers memory-keeper's dominant keyed working-state pattern (`session_goal`, `test_plan`, `build-complete-<ticket>`) without a schema. Omit `key` for a plain append-only message.
- **Advisory locks / presence are NOT in this model.** ("Who's editing what / who's live" is a later refinement built on `refs` + `UpdateLastSeen`, not a message type — see §7. v1 is: post and read.)

### 3.3 Read model — pull at the moments an agent can use it
- **SessionStart injection.** The existing recall-pack hook gains a **TEAM CHANNEL** section: active claims + recent posts from *other* sessions on this repo (self-deduped). A fresh session on any machine opens with "beelink, 20m ago: working X, opened PR #107, claimed `foo.ex`." This is the killer integration and it reuses machinery that already ships.
- **On-demand** via MCP (`channel_recent`, `presence`).
- **Turn-boundary freshness (v2).** A `UserPromptSubmit` (or `Stop`) hook pulls `channel_recent(since=last_seen)` each turn and injects deltas, so a long session stays current at **turn granularity — the finest granularity an agent can actually consume** — with no persistent connection. See §5.

### 3.4 Retention — uniform 30 days
Every post expires 30 days after its last write (`created_at`/`updated_at` + 30d). No per-type tiers — flat and simple (owner decision). A cheap Oban TTL sweep (same shape as the #411 graduation sweep) deletes expired rows.

The sweep is **alerted, not assumed healthy** (issue #498): `Loopctl.Workers.ChannelPostSweeper` emits telemetry on every run (success — including a zero-delete no-op — and failure, which is logged at `error` and re-raised/re-exited so Oban still retries), and `Loopctl.Knowledge.IngestionHealth.detect_sweep_stalled/0` records a tenant-scoped `:sweep_stalled` anomaly when a tenant's expired posts survive past the configured grace window *and* past what the bounded sweep could have drained in that window — the case where the worker stopped running entirely and therefore emits nothing. Because that cause is the single global sweeper, the OPERATOR alert is emitted once per detection run at system scope (listing the affected tenants) rather than once per tenant; the per-tenant anomaly row and its webhook stay per-tenant. That webhook is its own event type, `coordination.channel_post_sweep_stalled` — a retention event is not a knowledge-ingestion event, so it is never pushed at `knowledge.ingestion_anomaly_detected` subscribers.

Three properties of that detector are load-bearing and easy to break while tuning it. **The drain-capacity comparison is per tenant** (the candidate's own overdue count vs `sweep_drain_rate_per_hour × hours_stale`); making it install-wide turns `channel_posts` volume into a cross-tenant denial-of-detection lever. **`sweep_scan_limit` must exceed `sweep_drain_rate_per_hour × sweep_staleness_hours`** or the "merely backlogged" rule can never be observed and the drain-rate knob is inert. **Recovery closes on the RAW residue set and never on a truncated scan** — a candidate suppressed as backlogged, or missing from a saturated oldest-first sample, has not recovered, and closing it would write a false `resolved` retention claim into the append-only audit log (and re-arm detection, producing hourly flapping). The detector's own failures emit `Loopctl.TelemetryEvents.sweep_stall_detection_failed/0`, so the dead-man's switch dying is itself observable.

Two limits are deliberate and worth knowing: there is **no positive liveness heartbeat** — a never-scheduled sweeper is undetected for as long as no tenant has posts crossing `expires_at` + the grace window — and `channel_post_swept/0` is **emit-only in-app** (nothing in `lib/` attaches to it; `ScaleMetrics`/`ScaleAlerts` attach a curated subset), so it is a hook for an external reporter rather than an in-app alarm.

30 days is safe *because* the memory→knowledge graduation path (#411) already exists: the rare post worth keeping is promoted to the durable Knowledge plane; the rest was always disposable. This keeps the roll small and sharpens the three-plane separation instead of muddying it.

### 3.5 Schema (sketch)
```
channel_posts
  id            uuid pk
  tenant_id     uuid  (RLS)
  project_id    uuid  (the channel)
  agent_id      uuid  (server-stamped from key identity; never from body)
  session_id    text
  host          text
  key           text  null    -- optional; upsert on the keyed slot (see index below)
  body          text  not null
  refs          jsonb null     -- optional {file,pr,branch,commit}
  expires_at    timestamptz    -- created_at/updated_at + 30d (uniform)
  created_at    timestamptz
  updated_at    timestamptz
  -- indexes (as shipped): channel_posts_recent_seq_idx
  --            (tenant_id, project_id, inserted_at desc, seq desc),
  --          (expires_at) for the sweep,
  --          channel_posts_session_key_uidx -- PARTIAL unique
  --            (tenant_id, project_id, agent_id, session_id, key) where key is not null
```

The keyed slot is per **(tenant, project, agent, session)**, not project-global: `session_id` is
client-supplied and spoofable, so the server-stamped `agent_id` is part of the tuple
(`20260718000000_harden_channel_posts_slot_and_ordering.exs`) — one agent can never overwrite
another's working-state slot. Because the index is PARTIAL, any `ON CONFLICT` against it must use
a fragment conflict target carrying the columns **and** the `WHERE key IS NOT NULL` predicate
(US-39.2 AC-39.2.5); a bare column list raises Postgres `42P10` at runtime.
Ordering + tamper-evidence come from the existing audit chain + STH — no separate message-ordering system needed.

### 3.6 Tool surface
- **v1 (solves the pain):** `channel_post(project, body, key?, refs?)`, `channel_recent(project, since?, limit?)`, and the SessionStart TEAM CHANNEL block (default-on for every repo).
- **later:** `presence(project)` (from the existing `UpdateLastSeen` plug), a turn-boundary freshness hook (§5), and — if collisions prove painful in real use — an advisory soft-lock built on `refs`.

---

## 4. Security / tier posture

This is a **coordination surface, not chain-of-custody.** Posting/reading your own tenant's channel is not "approving your own work" — it is the same *content* class as the KB surface that owner decision #331 already made fully agent-usable. So: **agent-role, no `RequireHumanAnchor`**, RLS tenant-scoped, `agent_id` stamped server-side (never from the body). Cross-tenant isolation is the existing RLS boundary.

**Trust-surface note (updated by Epic 40 US-40.D3, owner signed-off decision 2).** v1 added no new *cross-tenant* trust surface — RLS remains the isolation boundary. Epic 40, driven by the security-adversary's prompt-injection blast-radius finding, DOES add one deliberate INTRA-tenant boundary: channel WRITES are scoped to the caller's own project (project membership / project-scoped keys), default-deny cross-project posting, so one compromised agent key cannot inject into every project channel across the tenant. This is a narrow write-authorization predicate (reads stay tenant-scoped + oracle-safe, unchanged), aligned with the multi-tenant/RLS rules — it refines, not replaces, the RLS posture. See `docs/user_stories/epic_40_coordination_bus_v2/us_40.d3.json`.

**Accepted residual (AC-40.D3.4, signed off).** The chosen membership source is a story assignment (`stories.assigned_agent_id`), and claiming a story is self-service for the `:agent` role — so a compromised agent key can contract + claim a pending story in a sibling project to self-grant membership there, narrowing (not fully closing) the intra-tenant injection vector. This is a DELIBERATE accepted risk, not a silent no-op: the claim is an audited, work-hijacking state change (observable), each post is blast-bounded by the 512-byte SessionStart preview, and the durable closure — binding a claim to a dispatch lineage so an agent can only claim work dispatched to it — is Chain of Custody v2 (Epic 26 L4, `docs/chain-of-custody-v2.md`), out of scope here because legacy env-var (non-dispatch) keys remain valid through the Epic 26 deprecation window. Per-project-scoped agent keys are the decision-2 compensating control in the interim. The `Loopctl.Coordination` moduledoc carries the full sign-off, and a labeled regression test keeps the accepted behavior visible so Epic 26 flips it consciously.

---

## 5. The realtime question (resolved: no websockets for agents)

The store is mandatory either way (late joiners, replay, audit, offline). The debate is only "store-and-pull" vs "store + push."

- **Agents consume at turn boundaries.** Unlike a human in Slack, an agent can't react to a mid-turn push — it reads context only at a turn boundary. Realtime's sub-second delivery is *wasted* on a consumer that can't look until its next turn.
- **Fly `auto_stop_machines = suspend`** is at war with long-lived connections; a stateless HTTP-read model is native to suspend-on-idle. (And beelink is reached over SSH — one more fragile socket.)
- **Ordering/atomicity/audit come from the DB,** which loopctl already has; WS would need its own.

**Decision:** store-and-poll, plus a turn-boundary freshness pull (§3.3). Push is deferred and, when built, is **for a human dashboard only** — an SSE feed (one-way, reconnects trivially, suspend-friendly) so Mark can *watch* his fleet coordinate. Agents never need it.

---

## 6. Retiring memory-keeper (a 3-item rebuild, not a parity project)

The audit (§1.2) makes this concrete. memory-keeper's used surface is three things, each with a home:

1. **key/value working state** (`context_items`, mostly uncategorized) → keyed posts (a post with an optional upsert `key` — there is no message-type taxonomy; §3.2).
2. **checkpoint handoff** (`build-complete-<ticket>`) → a keyed post (`key: build-complete-<ticket>`) — the piece that becomes **multi-machine** (the file checkpoint never was).
3. **cross-session history + search** → the 30-day roll is queryable; keepers graduate to Knowledge (permanent semantic search — the exact capability SETUP.md says degrades without memory-keeper).

Everything else (entities, relations, journal, compression, observations, agent-tasks, file-cache) has **zero fleet usage** — nothing to preserve.

**Honest tradeoff:** memory-keeper works offline (local SQLite); a hosted bus needs the network. Mitigation + sequencing:
- Files (`.claude/checkpoints/`, `.claude/state/*.md`) **stay as the local/offline source of truth**; the bus is the shared **multi-machine layer** over them (and supersedes the optional memory-keeper mirror immediately).
- The bus's own capture/writes degrade gracefully when loopctl is unreachable (same pattern as the capture hook), reconciling on reconnect.

**Sequencing (low-risk):** ship the bus v1 as the *wedge*; run it in real multi-machine use for a few weeks; if it delivers, migrate the three uses deliberately and retire the (already-demoted, optional) memory-keeper mirror. Never bet the memory system on an unproven design.

---

## 7. v1 scope (the wedge) — decisions locked

**v1 = two tools + one hook block:** `channel_post`, `channel_recent`, and SessionStart TEAM CHANNEL injection. That alone kills the manual-relay pain and unifies cross-machine awareness. Presence, turn-boundary freshness, and any advisory-lock refinement come later.

**Decisions (resolved with Mark, 2026-07-17):**
1. **Channel identity = `project_id`** (including `:kb` scopes). ✔
2. **Retention = 30 days**, uniform. ✔
3. **TEAM CHANNEL injection is created/on by default for every repo** (no per-repo opt-in). ✔
4. **memory-keeper retirement gate:** full migration of agent/skill references follows *flawless* real use of the new channels — the bus must prove itself first. ✔
5. **Keep it simple:** no message-type taxonomy, no per-type retention (§3.2, §3.4). ✔
   - **Reaffirmed (Epic 40, 2026-07-18):** the design panel floated an optional read-routing `kind` column; the owner declined. No message-type column — discovery routes on the stable `handoff:`/`claim:` key prefix. Story 40.A4 cut.
