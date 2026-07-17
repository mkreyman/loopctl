# Epic 40 — Coordination Bus v2 + memory-keeper retirement (deferred roadmap)

Follows **Epic 39** (the coordination-bus v1 wedge: post / read / inject / delete). This epic captures everything v1 deliberately deferred, written now while the design + codebase context is fresh so it isn't re-derived later. Design source: **`docs/repo-coordination-bus.md`** (§5 realtime, §6 retirement, §7).

**Gating:** none of this ships until v1 has proven itself in real multi-machine use (owner decision — "full migration follows flawless use of the new channels"). Phase C (retirement) is hard-gated on Phases A/B being in daily use.

**Reviewed:** these stories were run through a technical-grounding + security lens before commit; its corrections are folded in. Notably: graduation must use `Knowledge.propose_article/3` (the novelty gate) + a separate secret scan — `create_article/3` runs neither (US-40.1); the SSE dashboard needs a **human cookie/session auth** surface (browser `EventSource` can't send a Bearer header) plus SSE-framing + connection-cap hardening (US-40.6); the per-turn hook must **always exit 0** (a `UserPromptSubmit` non-zero exit erases the user's prompt) within a 30s budget (US-40.3); presence must not use agent-global `last_seen` (US-40.2); pagination reuses `Loopctl.KeysetCursor` (US-40.5). The rate-limiter has per-api_key + per-tenant buckets (no per-agent) — corrected in both epics' rate-limit ACs.

## Phases & decomposition

| Story | Title | Phase | Repo | Depends |
|-------|-------|-------|------|---------|
| US-40.1 | Graduate a channel post to Knowledge (retention-safety bridge) | A — v2 | loopctl | epic 39 |
| US-40.2 | Presence: who is live on this repo now | A — v2 | loopctl | epic 39 (US-39.3) |
| US-40.3 | Turn-boundary freshness pull (inject channel deltas each turn) | A — v2 | **claude-config** | US-39.6 |
| US-40.4 | Advisory soft-locks (claim/release a file target) | A — v2 | loopctl + claude-config | US-39.2, US-39.3 |
| US-40.5 | channel_recent pagination (cursor for deep history) | A — v2 | loopctl | US-39.3 |
| US-40.6 | SSE live dashboard — a human watches the fleet coordinate | B — human surface | loopctl (web) | US-39.3 |
| US-40.7 | memory-keeper retirement: usage inventory, migration, decommission | C — retirement (gated) | claude-config (+ fleet) | Phases A/B in daily use |

## Design anchors carried from v1

- **The three planes stay separate:** Knowledge (durable/curated), Memory (agent-private), Channel (repo-scoped/transient, 30d). US-40.1 is the bridge that makes "30-day hard delete loses nothing" literally true — the only story here that touches durability.
- **No realtime for agents.** US-40.3 (turn-boundary pull) is the near-realtime-for-agents mechanism — agents consume at turn boundaries, so a per-turn pull captures all the value a websocket could, without persistent connections (design §5). Realtime/SSE (US-40.6) is **for the human observer only**, one-way, and Fly-suspend-friendly.
- **Untrusted-content discipline is inherited.** US-40.3 (and any injection surface) reuses US-39.6's hardening: post bodies are JSON-encoded, fenced, truncated, fail-open, off-switch-aware.
- **Retirement is evidence-gated, reversible, per-repo.** US-40.7 starts with the audit (already partly done: only `context_items` + `checkpoints` + embeddings-search are used fleet-wide; the other ~12 memory-keeper feature areas have zero rows), maps each used capability to the bus/graduation, migrates one repo at a time behind a flag, and keeps files as the offline source of truth.

## Non-negotiable constraints (release gates, per story)

- Everything inherits epic 39's gates (tenant isolation via AdminRepo+explicit-filter, agent_id server-stamped, oracle-safety, agent-role/no-human-anchor, secret-scan, audit).
- **US-40.1** must not let an agent smuggle un-vetted content into the durable Knowledge plane at scale: graduation goes through the SAME novelty/secret gates as `knowledge_create`, is attributed, and is rate-bounded.
- **US-40.4** locks are ADVISORY (cooperative), never a hard mutex — they inform, they do not block; expiry + explicit release + a visible owner are required so a dead session can't wedge a file forever.
- **US-40.6** the dashboard is READ-ONLY and one-way (SSE), authenticated, tenant-scoped, and renders untrusted post bodies with the same escaping discipline as US-39.6 (it is a human-facing web view of agent-authored text — XSS surface).
- **US-40.7** is reversible at every step; no memory-keeper decommission until the bus has carried the three real use cases (state, handoff, search) in daily use, and files remain the local/offline fallback.
