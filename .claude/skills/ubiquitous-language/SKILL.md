---
name: ubiquitous-language
description: Glossary of loopctl's own vocabulary — the terms that cross the custody, knowledge and tenancy skills and therefore belong to none of them: the three information surfaces (retrieve_ vs knowledge_ vs memory_), custody words (exact-role, human anchor, trust tier, lineage, the self-* 409s), and the transparency-log words (audit chain, STH, inclusion proof, egress posture). Load it before acting on any term that is unfamiliar OR ordinary-looking-but-load-bearing here — scope, capability, graduate, novelty, cap, verify. Triggers on glossary, terminology, jargon, abbreviation, acronym, what does X mean, what do we call this, ubiquitous language, domain vocabulary.
---

# Ubiquitous Language — loopctl

The vocabulary that crosses skills. Every term recurs in two or more of `chain-of-custody`,
`knowledge-wiki`, `tenancy-rls`, `CLAUDE.md` and `docs/`, which is why it lives in an index rather
than in one of them. Use it to decode a term before acting on it, to use the platform's own name
when you write, and to find the skill that owns the full mechanism — this file is the index, not
the manual.

Terms that belong to exactly one surface stay in that surface's skill. Harness vocabulary that is
not loopctl's (the delivery loop, VCA, the recall pack) lives in the user-scoped
`ubiquitous-language` skill instead.

## Entry format

```
**Term** (a.k.a. alternate) — *Category*
One-sentence definition grounded in the actual code.
↳ See: `<the skill that documents it in full>`
```

---

## The three surfaces people conflate

Picking the wrong one is the most common vocabulary mistake here, and it is silent — all three
"store something for later".

**`retrieve_*` — Context Retriever** (Epic 30) — *Surface*
Governed, structured access to loopctl's **own live rows** (projects, stories, epics), through
`Loopctl.ContextRetriever.*` — a namespace, not a module. Pick it for live operational state.

**`knowledge_*` — Knowledge Wiki** — *Surface*
SHARED, curated tenant **documents**, deduped and linked (`Loopctl.Knowledge`). Pick it when the
insight is worth ANOTHER agent reading.

**`memory_*` — Agent Memory** (Epic 28) — *Surface*
PRIVATE `(tenant_id, subject_id)` working memory. Pick it for a fact only THIS agent needs about
its own work.
↳ See: `knowledge-wiki`

---

## A

**Audit chain** — *Transparency log*
The append-only, hash-linked record of custody transitions (Epic 26). It is what makes "nobody
marked their own work done" checkable after the fact rather than merely enforced at the time.
↳ See: `chain-of-custody`, `docs/chain-of-custody-v2.md`

## C

**Capability token** — *Custody*
The bearer of a delegated, scoped permission in the dispatch path — how an orchestrator hands an
agent the right to act without handing over its own role.
↳ See: `chain-of-custody`

**Chain of custody** — *Custody*
The core product guarantee: **nobody marks their own work as done.** An agent implements; an
independently-lineaged verifier confirms. Weakening a custody gate is the most dangerous change
class in this codebase.
↳ See: `chain-of-custody`

## E

**Egress posture** — *Trust*
The tenant's declared/observed outbound-network stance, bound into the audit chain and the STH so
that "zero third-party egress" is a **witnessed, verifiable claim** rather than an assertion in a
doc (US-41.7).
↳ See: `chain-of-custody`

**`exact_role:` vs `role:`** — *Custody — the distinction that holds the whole gate*
`role:` inherits up the hierarchy (`superadmin 4 > user 3 > orchestrator 2 > agent 1`);
`exact_role:` does NOT — a **higher** role is 403'd like any non-member. Every chain-of-custody
endpoint is exact-role gated, which is why a superadmin key cannot verify and a user key cannot
report. Never "normalize" an `exact_role` custody gate to `role:`: that is precisely what would
let one key both implement and verify.
↳ See: `chain-of-custody`

## G

**Graduation** (a.k.a. graduate) — *Knowledge*
Promotion of a HOT private memory into durable, shared knowledge. Graduated articles stay
**owner-visible, not peer-readable** by default, and a memory gets **one shot** — a failed
graduation insert still stamps it graduated.
↳ See: `knowledge-wiki`, `docs/agent-memory.md`

## H

**Human anchor / trust tier** — *Custody*
A gate on the TENANT's `trust_tier` (`:human_anchored` vs `:agent_rooted`), deliberately
**orthogonal to role**, applied by the opt-in `RequireHumanAnchor` plug. It is not a per-request
WebAuthn check — WebAuthn is how a tenant EARNS `:human_anchored`. Keying on tier rather than role
is what closes the self-minted-key bypass, and because the plug sits in no router pipeline, a new
human-rooted endpoint has NO tier gate until you add the line.
↳ See: `chain-of-custody`

## I

**Inclusion proof** — *Transparency log*
The public, unauthenticated endpoint that proves a specific leaf sits at a specific position under
a signed STH — so a third party verifies more than "some leaf exists".
↳ See: `chain-of-custody`

## L

**Lineage** — *Custody*
The dispatch ancestry of an actor. "Independently lineaged" is the property a verifier must have
relative to the implementer; it is what the self-`*` 409s enforce.
↳ See: `chain-of-custody`

## N

**Novelty gate** (a.k.a. the dedup/proposal gate) — *Knowledge*
The create-time assessment in `Knowledge.propose_article/3` with **six** outcomes, not four:
`:duplicate` (returns the canonical neighbor, but falls through to create if that neighbor
vanished), `:low_novelty` (created and forced to `draft`), `:unknown` (creates by default),
`:novel`, `:deduplicated` and `:skipped_low_novelty` (both `created: false`). A caller matching
only the first four falls through on the last two — both reachable.
↳ See: `knowledge-wiki`

## R

**RLS** — *Tenancy*
Row-level security: the database-enforced tenant isolation this platform relies on, as distinct
from query-level filtering. Read the skill before touching any query that crosses tenants.
↳ See: `tenancy-rls`

## S

**Scope** — *Ambiguous — but never a parameter you pass*
Across all three surfaces, scope is **key-derived server-side**: you never pass `tenant_id` or
`subject_id`. "Scope" also names a KB scope (`create_kb_scope` / `archive_kb_scope`) and
`ContextRetriever.Scope`; read which one is meant before wiring anything that looks like a tenant
filter.
↳ See: `knowledge-wiki`, `tenancy-rls`

**Self-`*` 409** (`self_report_blocked`, `self_review_blocked`, `self_verify_blocked`) — *Custody*
Not bugs and not rate limits: the custody guarantee refusing an actor who is trying to advance its
own work. A test or client that "fixes" one by escalating the key has defeated the product.
↳ See: `chain-of-custody`

**STH** (Signed Tree Head) — *Transparency log*
The ed25519-signed root of a tenant's audit chain, served with a public inclusion-proof endpoint,
so custody and egress claims are externally verifiable rather than self-reported.
↳ See: `chain-of-custody`

---

## Keeping this current

- **Add** a term once it recurs across ≥2 of {the domain skills, CLAUDE.md, `docs/`} and a fresh
  session would get it wrong from general knowledge. Recurrence is the bar, not importance.
- **Update** an entry in the same change that renames the thing — a glossary carrying a retired
  name misleads with authority.
- **Never** restate a mechanism a skill or doc owns; link to it.
