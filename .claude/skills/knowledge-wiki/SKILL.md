---
name: knowledge-wiki
description: Use when working on loopctl's knowledge/retrieval product — the shared Knowledge Wiki, agent memory, the context retriever, hybrid (curated + RAG) search, the novelty/dedup gate, embeddings, conflict resolution, or KB curation permissions. Covers the three agent information surfaces and how to pick between them. Triggers on: knowledge, wiki, knowledge_create, knowledge_search, hybrid_search, novelty, dedup, proposal gate, embedding, vector search, conflict, curation, memory_remember, memory_recall, retrieve_, context retriever, entity, RAG, progressive disclosure, OKF.
---

# Knowledge Wiki & Retrieval Surfaces

The knowledge/retrieval stack is loopctl's product core (it *is* the second brain). It is large
(`lib/loopctl/knowledge/`) and split across three distinct agent-facing surfaces plus a
hybrid retrieval capability. This skill routes you to the right surface and the load-bearing invariants;
full references live in `docs/agent-memory.md`, `docs/context-retriever.md`,
`docs/knowledge-hybrid-retrieval.md`. AGENTS.md carries the same three-surface routing for quick recall.

## Three surfaces — pick by WHAT THE DATA IS

| Surface | Module / tables | What it is | Pick when |
|---------|-----------------|------------|-----------|
| `retrieve_*` **Context Retriever** (Epic 30) | `Loopctl.ContextRetriever.*` — a NAMESPACE, not a module (`Scope`/`Executor`/`Registry`/`Entity`/`ToolGenerator` under `lib/loopctl/context_retriever/`; there is no `context_retriever.ex`), `entity_definitions` | governed, structured access to loopctl's own live rows (projects/stories/epics) | you'd query live operational state by a structured filter / full-text search |
| `knowledge_*` **Knowledge Wiki** | `Loopctl.Knowledge` (`lib/loopctl/knowledge.ex`) | SHARED, curated tenant DOCUMENTS, deduped + linked | the insight is worth ANOTHER agent reading |
| `memory_*` **Agent Memory** (Epic 28) | `Loopctl.Memory`, `memories`/`session_memories` | PRIVATE `(tenant, subject_id)` working memory | a fact only THIS agent needs to recall about its own work |

Rule of thumb: *live structured business row?* → `retrieve_*`. *worth another agent reading?* →
`knowledge_create`. *a fact only I need?* → `memory_remember`. Scope is **key-derived server-side** — you
never pass `tenant_id`/`subject_id`.

## Invariants (cited)

1. **Novelty / dedup gate on create** — `Knowledge.propose_article/3` → the private `gate_proposal/4`
   (`propose_article/3` at `knowledge.ex:441`; the four `gate_proposal/4` clauses at `:451-492`).
   **FIVE outcomes, not four** — `:duplicate`, `:low_novelty`, `:unknown`, `:novel`, and
   `:deduplicated` (`created: false`, returned when `create_article` hits the idempotency-key path,
   `knowledge.ex:507-508`). A caller matching only the first four falls through on a reachable
   response.
   `:duplicate` returns the canonical neighbor without creating; `:low_novelty`
   is created but **forced to `status: "draft"`** (`:467`) with novelty stamped into
   `metadata.proposal_novelty` (`stamp_proposal_metadata/2`, `:552-565`) so a smarter consumer decides.
   Two branches that are easy to miss: `:duplicate` **falls through to create** if the canonical
   neighbor vanished between assess and now (`:457-460`), and `:unknown` creates only BY DEFAULT — a
   caller passing `on_gate_unavailable: :skip` gets `{:error, :gate_unavailable}` and nothing is
   created (`:481-487`). The assessor is config-injected (`Loopctl.Knowledge.ProposalGate`, `:447-449`)
   — do not hardcode it.
2. **Hybrid search provenance** — `Loopctl.Knowledge.hybrid_search/3` (`knowledge.ex:8003`).
   `:curated` wins ONLY when a governed curated source's **absolute** (never pool-relative) confidence
   (`absolute_score/1`, `:8130-8135`) clears a scale-matched threshold AND beats the best retrieved
   candidate by a margin (`hybrid_curated_threshold_and_margin/1`, `:8181-8191`; the pure decision is
   `resolve_provenance/4`, `:8236-8246`) AND is authoritative (not superseded/conflicted — the caller
   passes only `list_curated_sources/2`-filtered scores). Otherwise `:retrieved`. Both branches return identical `results`/`meta`
   key sets — callers branch on `meta.provenance` alone. A sparse pool must never let a near-but-wrong
   curated doc win.
3. **All heavy KB reads route through `Loopctl.HeavyRead`** — semantic search, novelty, suggest-links,
   distant-pairs, enumeration (`knowledge.ex:12`). See the `tenancy-rls` skill for the pool/pgbouncer
   reasoning; never run these on `Repo`/`AdminRepo`.
4. **KB-content curation is agent-role and reversible (#331)** — `knowledge_create`, `knowledge_update`
   (ID-preserving in-place edit), `knowledge_archive`/`knowledge_delete` (soft delete → `status:
   :archived`, row retained), and `knowledge_resolve_conflict` in all dispositions are agent-role because
   each is reversible + audited. The `:user` set is single-article `unpublish` plus ALL the SET-BASED
   bulk ops — `bulk_publish`, `bulk_unpublish` and the ENTIRE `bulk_delete` action, soft path included
   (`article_workflow_controller.ex:37-39`). **Both criteria matter**: set-based blast radius (one call
   mutates an unbounded set) AND irreversibility (`bulk_delete` carries a hard-delete path) — see the
   controller `@moduledoc` (`:9-18`). Single-article ops are agent-role precisely BECAUSE they are
   reversible + audited, so never drop reversibility when reasoning about a new op.
   `drafts`/`publish` are `:orchestrator` (`:33`).
   Agent edits are visibility-scoped: an agent can only touch an article it can see. (See `chain-of-custody`.)

## Ranking changes are gated by the golden-question eval (#469)

Any change to `search_combined/3` ranking (weights, fusion, recency/authority) must ship with a
delta from `mix loopctl.retrieval.eval` — recall@k / MRR / nDCG against the committed golden set
(`priv/retrieval_eval/golden.jsonl`) and baseline (`priv/retrieval_eval/baseline_v1.json`). The
`retrieval-eval` CI job runs it in both the embeddings and keyword-only arms and gates `deploy`.
How to add a labeled question, re-baseline, and read the per-question winners/losers table:
`docs/runbooks/retrieval_eval.md`. Its semantic lane is a SYNTHETIC (provider-free) stand-in —
a regression instrument, not an absolute quality score.

## Anti-patterns

- Writing a private, task-local fact via `knowledge_create` (pollutes shared KB) — use `memory_remember`.
- Curating a live operational row into the wiki instead of exposing it via a Context Retriever entity.
- Branching caller logic on which subsystem answered instead of `meta.provenance`.
- Bypassing `propose_article`'s gate to force-create a near-duplicate.
- A heavy vector read on `Repo`/`AdminRepo` (starves the admin pool) — route through `HeavyRead`.
- Treating `hybrid_search` confidence as pool-relative — it is absolute, scale-matched, margin-gated.
- Re-baselining the retrieval eval to turn a red gate green (the numbers move only with a reviewed
  ranking change).

## Related

- **`tenancy-rls`** — the `HeavyRead`/`HeavyReadRepo` pool every KB read uses; RLS scoping.
- **`chain-of-custody`** — the role model and the #331 KB-content carve-out.
- Ecto query composition behind `list_*`/search: the global `patterns-ecto` skill.
