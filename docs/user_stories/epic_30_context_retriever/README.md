# Epic 30 — Context Retriever (entity-schema → auto-generated agent tool surface)

Decomposition of GitHub issue **#309** — Cole Medin's **second** production pillar (the first is
Agent Memory, epics 28–29). A per-tenant **entity/schema layer** auto-generates the agent tool
surface (filter + full-text tools) over **structured** data, so an agent queries in a single
governed tool call instead of scanning documents or hand-writing SQL.

> **Status: authored with `user-story-writer` (current schema, `estimated_tokens`).**
> Pending the three-lens enhanced review (analyst / architect / adversarial) before
> `/implement-plan`, same as epics 28–29.

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

The executor turns model output into database queries, so v1 is security-first: **allowlist only**
(a tool can only touch fields an entity marks filterable/searchable), **parameterized always** (an
injection payload is a literal value, never SQL), **mandatory non-overridable tenant scoping**,
**role gating** (define ≥ user, query ≥ agent), **capped pagination**, and **declared-fields-only
result shaping** (no undeclared/audit column leakage). The dogfood (US-30.6) proves parity against
loopctl's known-good hand-written story/project tools; US-30.7 proves the security properties
epic-wide across API + MCP.

## Provenance

Second Brain: hub `3ee5f890` (Cole Medin context-retriever pillar), `489d675d`/`29ecd697`
(loopctl entity-relationship ideas), `aef099c3` (the Karpathy LLM-wiki pattern this scales past).
GitHub #309.
