# Epic 30 — Context Retriever (entity-schema → auto-generated agent tool surface)

Decomposition of GitHub issue **#309** — Cole Medin's **second** production pillar (the first is
Agent Memory, epics 28–29). A per-tenant **entity/schema layer** auto-generates the agent tool
surface (filter + full-text tools) over **structured** data, so an agent queries in a single
governed tool call instead of scanning documents or hand-writing SQL.

> **Status: authored with `user-story-writer`, hardened through one enhanced-review round.**
> Three-lens review (analyst / architect / adversarial-security), each verified against the live
> code, found three blockers (self-authored allowlist, unbuildable full-text, vacuous role gate)
> and safety gaps — all applied (see "Review changes"). A confirm-pass before `/implement-plan`
> is still worthwhile.

## Distinct from the Knowledge Wiki (and Agent Memory)

Three complementary layers — the mental model this whole effort clarified:
- **Knowledge Wiki** (#305/#306) — retrieval over *curated knowledge articles*.
- **Agent Memory** (#307/#308) — *scoped, auto-accumulated* per-agent working state.
- **Context Retriever** (this epic) — *governed, schema-driven access to live structured records*.

Do not conflate them; `retrieve_*` is not `knowledge_search` is not `memory_recall`.

## Scope boundary

- **In scope (v1):** entity definitions + registry, tool generator, the **safe** query executor,
  the API (entity CRUD + generated-tool listing + generic execute), **dynamic MCP tool listing**,
  and a **dogfood** over loopctl's own projects/stories/epics.
- **Backing sources v1:** loopctl-internal tables only (projects/stories/epics). **Tenant-supplied
  external sources are a future epic** — v1 proves the pattern on data loopctl already exposes.
- **No web UI.** loopctl is agent-native; the #309 entity-designer LiveView is dropped — entity
  management is via the API/MCP.

## Story map

| Story | Title | Surface | Depends on |
|-------|-------|---------|-----------|
| US-30.1 | Entity-definition schema + migration + per-tenant registry | domain/db | — |
| US-30.2 | Tool generator: entity → filter + full-text tool specs | domain | 30.1 |
| US-30.3 | Query executor: generated call → safe scoped Ecto query (**security core**) | domain | 30.1, 30.2 |
| US-30.4 | API: entity CRUD + `/retrieve/tools` + `/retrieve/:entity` | api | 30.3 |
| US-30.5 | Dynamic MCP tool listing (static + per-tenant generated) | mcp | 30.4 |
| US-30.6 | Dogfood: loopctl projects/stories as entities; parity with hand-written tools | domain | 30.5 |
| US-30.7 | Docs (three-layer model) + terminal security verification (runs last) | docs/verify | all |

## Security is the theme (US-30.3 is the crux)

The executor turns model output into database queries, so v1 is security-first:
- **Server per-source column allowlist** (US-30.1): the entity def is authored by a `≥user` admin,
  so a *server* constant bounds which columns each backing source may expose — an admin can't
  declare `tenant_id`/audit/custody columns. Validated at define AND execute time.
- **Parameterized always** — injection payloads (filter values *and* search queries) are literals.
- **Mandatory non-overridable tenant scoping** — RLS context *and* an explicit predicate; isolation
  tests run under the non-owner app role (RLS is `ENABLE`, not `FORCE`, so an owner connection
  bypasses it and would prove nothing).
- **Indexed full-text** — a GIN tsvector migration on the backing tables (they have none off
  `articles`); no on-the-fly `to_tsvector` seq-scan, no `ILIKE`.
- **Role gate**: define ≥ user; querying needs only authentication (`agent` is the floor role, so
  a "below-agent 403" doesn't exist — the negative case is 401).
- **Audit + rate-limit + entity cap**: every execution is audited; `/retrieve` is Hammer-rate-limited;
  entities-per-tenant are capped so dynamic `ListTools` stays bounded.
- **Declared-fields-only result shaping**; **relationships deferred out of v1** (no unvalidated JSON).

The dogfood (US-30.6) proves the generated path is **not a broader read surface** than loopctl's
vetted `list_stories` (which is per tenant+epic); US-30.7 proves the security properties epic-wide.

## Review changes (enhanced-review round 1, applied)

Added the server per-source column allowlist (blocker: entity def was a self-authored allowlist);
replaced the "reuse the articles full-text path" (which exists only on `articles`) with a GIN
tsvector migration on the backing tables (blocker: full-text was unbuildable safely); fixed the
vacuous "query ≥ agent" gate to authentication-only + 401 negatives (blocker: agent is the floor
role); added execute-time allowlist re-validation, audit logging, `/retrieve` rate-limiting, a
per-tenant entity cap, superadmin/stale-def fail-closed edges, `{:array,:map}` fields (no embeds in
this codebase), RLS-on-migration + non-owner-role isolation tests, MCP structured-args dispatch,
search execution tests, and re-baselined the dogfood parity oracle; deferred relationships out of v1.

## Provenance

Second Brain: hub `3ee5f890` (Cole Medin context-retriever pillar), `489d675d`/`29ecd697`
(loopctl entity-relationship ideas), `aef099c3` (the Karpathy LLM-wiki pattern this scales past).
GitHub #309.
