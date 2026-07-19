# Epic 40 (re-scoped) — Repo Coordination Bus: agent-native handoff & coordination

Follows **Epic 39** (the coordination-bus v1 wedge: post / read / inject / delete).
This epic was **re-scoped by a completed 5-reviewer design panel** (constructive BA +
Elixir systems architect; adversarial BA + architect + security-adversary). The panel
inverted v1's "pointer-board-only" lean and corrected several concrete defects. This
folder now carries **only the loopctl SERVER surface**; the claude-config client/skill
companion is tracked separately (see the bottom).

## Framing (the correction)

loopctl is **agent-native, multi-tenant, concurrent, and adversarial** (chain-of-custody
v2, the sneaky-vs-lazy-bastard threat model). The bus must serve **many agents on the same
repo, across machines and tenants, some mutually distrusting** — NOT a solo
human-in-the-loop. That inverts the earlier lean: **exactly-once claim, directed discovery,
and the security guardrails are load-bearing, not gold-plating.**

The driving use case is the real **beelink → mac-mini #812** handoff. v1 removed copy-paste
of *content*; it did NOT deliver *"handled exactly once, not dropped."* A human still had to
NOTICE and ROUTE the handoff. This epic closes that gap.

### Design invariants (what the whole thing rests on)

1. **Payload lives in a durable home; the bus carries a discoverable, claimable POINTER.**
   Durable home = a GitHub issue/PR, a `docs/` file, or **Knowledge** (40.E1, for a reusable
   finding with no external tracker). The bus body stays a bounded TL;DR + pointer.
2. **The channel is a subscription surface (Slack semantics).** Working a repo = membership.
   (The push/opt-out mechanics are the claude-config companion; loopctl exposes the reads.)
3. **Handoff is claimable exactly-once.** Concurrent agents race; the winner claims, the
   loser sees `409 already_claimed`. Done-state is explicit. (40.B1)
4. **Reads are as hardened as the SessionStart hook** — bounded previews framed as untrusted
   DATA, never full un-fenced bodies (the panel's biggest miss). (40.D1)
5. **Spoofable fields (`host`, `session_id`, `to_host`, `to_capability`) are advisory /
   surfacing ONLY, never authorization.** (40.A5)

## Stories (loopctl server surface), grouped A–E

Numbering scheme: the **re-scoped active work uses letter suffixes** (`us_40.a1.json` …
`us_40.e1.json`) grouped A–E; **pre-existing carried-over stories keep their original
numbers** (`us_40.2`, `us_40.4`, `us_40.6`, `us_40.7`). Letters = new rescope; numbers =
carried over. `40.A2` was DROPPED at sign-off (see below).

### Group A — Data-model & write-path corrections
| Story | Title |
|-------|-------|
| **40.A1** | `refs` as a typed-open LIST `[{type,value,label?}]` + scan type/value/label + count cap (the one genuine shipped defect) |
| **40.A3** | Drop the redundant `channel_posts_recent_idx` (write-amplification bug fix) |
| **40.A4** ⚠️ | Optional open indexed `kind` for read-routing (NOT an enum, NOT retention-tied). **BLOCKED: OPEN owner-decision gate** — see below; also adds AC-40.A4.5 (server-enforced non-null key for `kind=handoff`) that makes 40.C1's exactly-once discovery join sound. |
| **40.A5** | Advisory addressing: `to_host` / `to_capability` (surfacing-only, never authz) |

### Group B — Claim / exactly-once lifecycle
| Story | Title |
|-------|-------|
| **40.B1** | `channel_claims` table — INSERT-to-claim, `UNIQUE(tenant,project,ref)`, `409 already_claimed`, lifecycle-aware sweep, claim/release/done MCP |
| **40.B2** | Idempotency — stable `handoff:<anchor>` key + optional client idempotency token on keyless writes |

### Group C — Discovery & delivery
| Story | Title |
|-------|-------|
| **40.C1** | Directed-handoff discovery read: open/unclaimed handoffs for me/my capability (kind + addressing + NOT EXISTS open claim), pinned above recency |
| **40.C2** | Delta/cursor read on `(inserted_at, seq)` + commit-lag lost-write fix + previews-not-bodies (**supersedes old US-40.5**) |

### Group D — Security guardrails (load-bearing; from the security-adversary)
| Story | Title |
|-------|-------|
| **40.D1** | Harden the read path: bounded previews as untrusted DATA + oracle-safe `GET /channel/posts/:id`, no auto-follow lever |
| **40.D2** | Restrict redact/delete to the post's OWN author (or elevated role) — kill the censor-and-replace vector |
| **40.D3** | Scope channel WRITES to the caller's own project (membership) — default-deny cross-project posting |
| **40.D5** | Read rate-limit + response byte-cap on index/show (today only `:create` has the tight cap) |

*(No 40.D4: the D-group ships D1/D2/D3/D5 — 40.D4 was folded into 40.D5 during panel
sequencing (read rate-limit + response byte-cap are one story), leaving the number retired
rather than a separate story. Numbering is intentional, not an omission.)*

### Group E — Durability bridge
| Story | Title |
|-------|-------|
| **40.E1** | Graduate-to-Knowledge for a reusable finding with no external tracker — content-selective, NOT graduate-every-handoff (**refocus of old US-40.1**) |
| **US-40.7** | memory-keeper retirement: inventory, per-repo migration, decommission (gated, reversible) — carried over, essentially unchanged |

## Blocking gates (must clear before the gated stories are implemented)

- **40.A4 — OPEN owner-decision gate (blocks A4 and, transitively, C1).** `us_40.a4.json`
  carries an `owner_decision_conflict` marked **OPEN**: reintroducing an indexed `kind`
  un-bundles the owner's locked "no message kind" decision
  (docs/repo-coordination-bus.md §3.2 / §7 decision 5) on panel authority, which only the
  owner can authorize. **A4 must NOT be implemented until Mark signs off** on the
  routing-only `kind` (and the doc is amended + added to "Signed-off decisions folded in").
  Because **40.C1 depends on 40.A4**, the entire directed-discovery half (C1) is blocked
  behind this gate too. This is NOT a panel-decided fold-in — do not treat A4/C1 as
  ordinary committed work until the gate clears.
- **40.B1 claim writes — membership gate coupling (see D3).** B1 now depends on 40.D3 so
  claim/release/done ship membership-gated; D3's shared predicate lands with or before
  B1's claim writes (see the dependency-edges note above).

## Suggested sequencing (each step safe alone)

1. **40.A3** (index cleanup, zero-risk)
2. **40.A1** (the shipped refs defect + key/label scan)
3. *(40.A2 DROPPED — see decisions)*
4. **40.D1 + 40.C2** (bounded read previews + oracle-safe `GET /:id` + cursor / lost-write fix) — they co-own the read path
5. **40.B1 + 40.B2** (claim table + idempotency) — B1's claim writes are membership-gated
   by 40.D3's shared predicate, so land D3's `project_writable_by_agent` with or before
   this step (B1 → 40.D3)
6. **40.A4 + 40.A5** (`kind` + advisory addressing) — ⚠️ **40.A4 is BLOCKED on the OPEN
   owner-decision gate** (see "Blocking gates"); do not implement A4 until Mark signs off
7. **40.C1** (directed discovery — composes A4 + A5 + B1) — transitively blocked by the
   A4 owner gate; A4.5's server-enforced handoff key is what makes C1's exactly-once join
   sound
8. *(turn-boundary push + subscription + skill-awareness → claude-config companion)*
9. **40.D2 + 40.D3 + 40.D5** (delete gate, write scoping, read limits)
10. **40.E1** (graduate bridge) → then **US-40.7** (retirement, hard-gated)

Dependency edges encoded in the JSON: 40.B2→40.B1; 40.B1→40.D3; 40.C2→40.D1; 40.C1→{40.A4,40.A5,40.B1,40.B2,40.D1};
40.D5→40.D1; 40.E1→{40.D1,40.D3}; US-40.7→40.E1. (40.B1 depends on 40.D3 because the
CLAIM writes (claim/release/done) must be membership-gated by the SAME
`project_writable_by_agent` predicate 40.D3 adds to the post write — otherwise a
same-tenant non-member could claim/block or release handoffs in a sibling project, the
exact cross-project blast radius D3 closes for posting. D3's shared predicate therefore
lands with or before B1's claim writes; if the numbered order below is kept, pull it
forward or co-deliver B1+D3.) (40.C1 depends on 40.B2 because its
NOT-EXISTS-open-claim join is `claims.ref = posts.key`, which needs B2's stable
`handoff:<anchor>` key; and on 40.D1 because the directed-handoff read returns other agents'
bodies and must reuse D1's bounded-preview / untrusted-DATA read-hardening.) The A-group
data-model stories and the D2/D3 guardrails have no in-epic prerequisites (they modify shipped
Epic 39 code).

## Old → new map

| Old (v1-deferred) | Disposition |
|-------------------|-------------|
| US-40.1 graduate-to-Knowledge | **Refocused → 40.E1** (content-selective; NOT the general handoff-durability answer). File `us_40.1.json` removed. |
| US-40.2 presence | **DEFERRED** (kept as `us_40.2.json`, marked deferred). |
| US-40.3 turn-boundary pull | **Moved to claude-config** companion (a Claude Code hook, not loopctl code). File `us_40.3.json` removed from this epic. |
| US-40.4 file soft-locks | **Retained + clarified** (`us_40.4.json`): advisory collision-avoidance, explicitly **NOT** the exactly-once handoff claim (40.B1 is). |
| US-40.5 pagination | **Superseded → 40.C2** (its `(inserted_at, id)` keyset was a panel-rejected defect; C2 keysets on `(inserted_at, seq)` + fixes the lost-write hazard). File `us_40.5.json` removed. |
| US-40.6 SSE dashboard | **DEFERRED** (kept as `us_40.6.json`, marked deferred). |
| US-40.7 retirement | **Carried over**, essentially unchanged (deps repointed to 40.E1). |
| — | **New:** 40.A1, 40.A3, 40.A4, 40.A5, 40.B1, 40.B2, 40.C1, 40.C2, 40.D1, 40.D2, 40.D3, 40.D5. |

## Deferred (on their own merits — not "solo")

- **US-40.2 Presence** — collision-avoidance value, but ranks below claim (40.B1) + discovery
  (40.C1). Revisit after those are in daily use.
- **US-40.6 SSE dashboard** — operator oversight; agents don't consume SSE (they consume at
  turn boundaries), and human oversight already has the superadmin API path. Heaviest lift,
  least coordination value.
- **Abandoned/expiring-unclaimed-handoff ALERT (panel agreed-gap #4, second half) —
  DEFERRED with rationale.** Gap #4 has two halves: (a) a DONE handoff lingering as noise —
  **addressed** by 40.B1's lifecycle-aware sweep; and (b) a directed handoff that reaches
  the 30-day TTL still UNCLAIMED, expiring silently with no alert. Half (b) is deliberately
  deferred: 40.C1 already pins **oldest-unclaimed-first** so an aging directed handoff floats
  to the top of the discovery read the moment any eligible session looks, which is the
  agent-native surfacing path (agents consume at turn boundaries, not via a push alarm).
  A dedicated expiry-escalation alert is operator-oversight tooling (same class as the
  deferred SSE dashboard, US-40.6) and belongs with that oversight surface, not the
  claim/discovery critical path. Revisit alongside US-40.6 if unclaimed-handoff expiry
  proves a real loss in daily use; the TTL is 30 days, so the risk window is long.

## Carried-over stories retained off the critical A–E path

- **US-40.4 Advisory file soft-locks** (`us_40.4.json`) — **Retained + clarified**
  (advisory, non-exclusive collision-avoidance on FILE targets; explicitly NOT the
  exactly-once handoff claim, which is 40.B1). It builds only on shipped Epic 39 code
  (channel_posts + a short TTL) plus the indexed `kind='claim'` filter once 40.A4 lands,
  so it has no in-epic prerequisite beyond A4's `kind` (falls back to a `key LIKE 'claim:%'`
  scan if A4 has not landed). It is NOT on the numbered A–E claim/discovery sequence; land
  it any time AFTER 40.A4 (step 6). Distinct from the Deferred set (40.2, 40.6) — it IS in
  scope, just off the critical path.

## Signed-off decisions folded in

1. **Body cap = 16 KB (unchanged).** No 2 MB, no bump. Consequently `@scan_byte_cap`
   already equals `@body_max_length` (channel_post.ex:45, 211) so the whole body is always
   scanned — **40.A2 (decouple scan cap) is DROPPED**: no change needed unless the cap is
   raised, which it isn't.
2. **Membership = the session's OWN project channel by default.** Server-side, **40.D3**
   enforces write-to-own-project (project-scoped keys / membership), default-deny
   cross-project posting.
3. **Delete/redact = the post's OWN author (or elevated role)** — **40.D2**. Kills the
   any-agent censor-and-replace vector while preserving self-leak-pullback. (Final owner
   nod pending between author-only vs removing agent-delete entirely; written as
   author-only, alternative flagged in 40.D2's ACs.)
4. **Running-session notification is a claude-config/SKILL concern, NOT loopctl.** loopctl
   exposes only the delta/cursor read (40.C2). The turn-boundary push / periodic-pull moves
   to the companion set.
5. **Whole epic authored in one go**, then run the enhanced review ON the written story set
   before implementation.

## claude-config companion (tracked separately — OUT OF SCOPE for this epic)

The client/skill half is a separate claude-config work item, NOT loopctl server stories:
- **Running-session turn-boundary awareness** (a `UserPromptSubmit`/Stop hook pulling the
  40.C2 delta since the session's last-seen cursor; the formerly-numbered US-40.3) — verify
  the Claude Code hook capability there.
- **Subscription / opt-out semantics** surfaced to the agent (`CLAUDE_TEAM_CHANNEL=0` opts
  out of push, keeps pull membership) + skill-awareness (actively check for directed
  handoffs during long work; claim before acting).
- **The `/handoff` skill** — write payload to the durable home → post a keyed pointer
  (`kind=handoff`, `to_capability`, refs anchor, stable `handoff:<anchor>` key, TL;DR body)
  → receiver discovers (40.C1), claims (40.B1), acts, marks done.
- SessionStart injection (US-39.6) already shipped.

## Inherited gates (per story, from Epic 39)

Tenant isolation via AdminRepo + explicit tenant filter; `agent_id` server-stamped;
oracle-safety (byte-identical 404s, no existence oracle); agent-role/no-human-anchor on the
coordination surface (#331); secret-denylist scan; append-only, hash-chained audit. New
tables use `ENABLE ROW LEVEL SECURITY` (not FORCE) per the multi-tenant rule, and every
context module ships a tenant-isolation test case.
