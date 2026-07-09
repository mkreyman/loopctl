# Epic 28 — Agent Memory (Part 1: store + semantic retrieval)

Decomposition of GitHub issue **#307** (Agent Memory — Part 1: per-scope memory store +
semantic retrieval). This is the **substrate**: a first-class, tenant/project/agent-scoped
memory subsystem — short-term *session memory* + long-term, vector-retrieved *promoted
memory* — distinct from the Knowledge Wiki.

> **Status: FIRST-DRAFT SCAFFOLD — not yet review-hardened.**
> These stories were authored quickly to give #307 an implementable shape. Before running
> `/implement-plan`, refine them with the `user-story-writer` skill and put them through the
> enhanced-review pass (the way epic_27 was), then verify every AC against the live code.

## Scope boundary (read first)

- **In scope (Part 1):** the memory *store* (schemas, migrations), the `Loopctl.Memory`
  context (`remember`/`recall`/`forget`/`list`/`supersede`), the embedding pipeline for
  memories, the HTTP API, the MCP `memory_*` tools, the human Memory-Inspector LiveView,
  and docs. Memory is written **explicitly** by an agent/user in Part 1.
- **Out of scope (Part 2 = #308):** the *auto-promotion / session-memory compiler* (the
  Oban job that extracts golden nuggets from session memory into long-term memory without
  the agent being explicit). Part 2 depends on this epic.
- **Sibling pillar (#309):** the Context Retriever (structured business-data access) is a
  separate epic, not here.
- **Adjacent, NOT this:** #305 / #306 (curated + RAG *knowledge* interface) operate on the
  Knowledge Wiki. Do **not** overload `knowledge_*` / the `articles` table for memory.

## How to implement (later, once reviewed)

```
/implement-plan --epic docs/user_stories/epic_28_agent_memory
```

Epic mode topologically sorts by each story's `dependencies` and drives each through
implement → enhanced review → zero-deferral fix → `mix precommit` → CI-gated squash-merge.
WIP=1, dependency-blocked.

## Story map

| Story | Title | Surface | Depends on |
|-------|-------|---------|-----------|
| US-28.1 | Schemas + migrations: `session_memories` + `memories` (embedded, HNSW), scoped | domain/db | — |
| US-28.2 | `Loopctl.Memory` context + embedding worker (remember/recall/forget/list/supersede) | domain | 28.1 |
| US-28.3 | HTTP JSON API `/api/v1/memory*` (+ OpenAPI, auth pipeline) | api | 28.2 |
| US-28.4 | MCP `memory_*` tools (+ docstrings disambiguating memory vs knowledge) | mcp | 28.3 |
| US-28.5 | Memory-Inspector LiveView (browse / search / delete per scope) | app | 28.2, 28.3 |
| US-28.6 | Docs + terminal cross-surface scope-isolation verification (runs last) | docs/verify | all |

## Reuse (don't reinvent)

pgvector is already a dependency and enabled (`20260410022854_enable_pgvector_and_add_embedding.exs`).
Memory reuses the existing embedding infra: `Loopctl.Knowledge.EmbeddingClient` (per-tenant BYO
key), `VectorSearch` (HNSW kNN), `EmbeddingCircuitBreaker`, and the HNSW index helper
`lib/loopctl/repo/hnsw_index.ex`. The embedding worker mirrors
`lib/loopctl/workers/article_embedding_worker.ex`. Auth reuses the `:authenticated` pipeline and
`Loopctl.Auth.Role` (`superadmin > user > orchestrator > agent`). Scoping reuses `SetTenant` + RLS.

## Provenance

Second Brain hub `3ee5f890` (Cole Medin — *"…the Karpathy LLM Wiki … Doesn't Scale…"*, agent-memory
pillar) + revived idea `787761cd` (loopctl × mcp-memory-keeper). GitHub #307.
