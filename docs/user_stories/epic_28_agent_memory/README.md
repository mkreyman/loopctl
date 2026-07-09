# Epic 28 — Agent Memory (Part 1: store + semantic retrieval)

Decomposition of GitHub issue **#307** (Agent Memory — Part 1: per-scope memory store +
semantic retrieval). This is the **substrate**: a first-class, tenant/subject-scoped memory
subsystem — short-term *session memory* + long-term, vector-retrieved *promoted memory* —
distinct from the Knowledge Wiki.

> **Status: authored with `user-story-writer`; hardened through one enhanced-review round.**
> The stories follow the skill schema and the epic_27 convention. They were then put through a
> three-lens enhanced review (analyst / architect / adversarial), each verifying findings
> against the live code; all confirmed findings were applied (see "Review changes" below).
> A second confirm-pass before `/implement-plan` is still worthwhile, but the known blockers
> are resolved.

## Scope boundary (read first)

- **In scope (Part 1):** the memory *store* (schemas, migrations), the `Loopctl.Memory`
  context (`remember`/`recall`/`forget`/`list`/`session_history`/`supersede`), the embedding
  worker, the session-prune worker, the HTTP API, and the MCP `memory_*` tools. Memory is
  written **explicitly** by an agent in Part 1.
- **Out of scope (Part 2 = #308):** the *auto-promotion / session-memory compiler*. Part 2
  depends on this epic.
- **Sibling pillar (#309):** the Context Retriever (structured business-data access).
- **Adjacent, NOT this:** #305 / #306 (curated + RAG *knowledge* interface) operate on the
  Knowledge Wiki. Do **not** overload `knowledge_*` / the `articles` table for memory.
- **No web UI.** loopctl is agent-native — API-key auth only, no human web login. There is
  **no LiveView / inspector**. Operator visibility + delete is a **superadmin-gated API path**
  (US-28.3 AC-28.3.4), the agent-native equivalent of Cole Medin's "operator control."

## How to implement (once the confirm-pass is done)

```
/implement-plan --epic docs/user_stories/epic_28_agent_memory
```

Epic mode topologically sorts by each story's `dependencies` and drives each through
implement → enhanced review → zero-deferral fix → `mix precommit` → CI-gated squash-merge.
WIP=1, dependency-blocked. `@tag :scale` checks are excluded from `mix precommit` and executed
by the terminal story US-28.5 (the epic_27 pattern).

## Story map

| Story | Title | Surface | Depends on |
|-------|-------|---------|-----------|
| US-28.1 | Schemas + migrations: `session_memories` (with expiry) + `memories` (embedded, HNSW), scoped; pinned `subject_id` + `superseded_by on_delete: :nilify_all` | domain/db | — |
| US-28.2 | `Loopctl.Memory` context + embedding worker + session-prune worker; recall scope-guarded on the BYPASSRLS heavy-read path | domain | 28.1 |
| US-28.3 | HTTP JSON API `/api/v1/memory*` + superadmin oversight (+ OpenAPI) | api | 28.2 |
| US-28.4 | MCP `memory_*` tools (+ docstrings disambiguating memory vs knowledge) | mcp | 28.3 |
| US-28.5 | Docs + terminal cross-tenant/cross-subject isolation, scale-recall & e2e verification (runs last) | docs/verify | all |

## Reuse (don't reinvent)

pgvector is a dependency and enabled (`20260410022854_enable_pgvector_and_add_embedding.exs`).
Memory reuses `Loopctl.Knowledge.EmbeddingClient` (per-tenant BYO key), the HNSW kNN path
(`Loopctl.Knowledge.VectorSearch` is article-bound — **extract a shared helper**),
`EmbeddingCircuitBreaker`, and the HNSW index helper `lib/loopctl/repo/hnsw_index.ex`. The
embedding worker mirrors `lib/loopctl/workers/article_embedding_worker.ex` (flat
`Loopctl.Workers.*` namespace). Auth reuses the `:authenticated` pipeline and
`Loopctl.Auth.Role` (`superadmin > user > orchestrator > agent`, agent = floor).

## Security model (the review's core lesson)

- **Two scope keys:** `tenant_id` **and** `subject_id`. `subject_id` is derived server-side from
  the API key (`agent_id` for agent keys, else `api_key.id`) and is never client-supplied.
- **Isolation is split by path.** Writes/list/forget on `Loopctl.Repo` ride **RLS**. But semantic
  **recall runs on `Loopctl.HeavyReadRepo` (BYPASSRLS)** — its isolation is an *explicit*
  `(tenant_id, subject_id)` predicate enforced by a **structural guard** (extend
  `HeavyRead.guard!/2` to require `subject_id`, as it already requires `tenant_id`). Do not
  assume RLS covers recall.
- **Index-safety:** a selective `(tenant_id, subject_id)` btree filter defeats HNSW (#170/#172),
  so subject scoping uses over-fetch + post-filter (or partitioned retrieval) with an
  at-scale EXPLAIN gate — otherwise an agent silently fails to recall its own memories.

## Review changes (enhanced-review round 1, applied)

Three-lens review against live code found and fixed: **(blocker)** removed the human-auth
LiveView story — loopctl has no `on_mount`/users/session login; **(blocker)** pinned the
`subject_id` derivation (nullable `agent_id` + agent-as-floor-role would have leaked/failed);
**(blocker)** corrected recall isolation from "RLS" to the BYPASSRLS heavy-read structural
guard + index-safe subject filtering; **(majors)** added the session-memory read path
(`session_history/2`), TTL + prune worker, `superseded_by on_delete`, and the previously
untested ACs (pagination/total_count, worker idempotency, MCP witness self-heal, recall-supersede
exclusion, API-level cross-subject isolation); **(minors)** worker namespace, OpenAPI operations
location, role-gate intent, write quota/rate-limit, PII stance, observable isolation assertions.

## Provenance

Second Brain hub `3ee5f890` (Cole Medin — *"…the Karpathy LLM Wiki … Doesn't Scale…"*, agent-memory
pillar) + revived idea `787761cd` (loopctl × mcp-memory-keeper). GitHub #307.
