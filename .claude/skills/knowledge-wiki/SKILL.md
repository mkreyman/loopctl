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
   (`propose_article/3` at `knowledge.ex:456`; the four `gate_proposal/4` clauses at `:466-518`).
   **SIX outcomes, not four** — `:duplicate`, `:low_novelty`, `:unknown`, `:novel`,
   `:deduplicated` (`created: false`, returned when `create_article` hits the idempotency-key path,
   `knowledge.ex:571-573`), and `:skipped_low_novelty` (`created: false`, `article` may be `nil`).
   A caller matching only the first four falls through on either of the last two, both reachable.
   `:duplicate` returns the canonical neighbor without creating; `:low_novelty`
   is created but **forced to `status: "draft"`** (`:492`) with novelty stamped into
   `metadata.proposal_novelty` (`stamp_proposal_metadata/2`, `:692-705`) so a smarter consumer decides
   — UNLESS the caller passes `on_low_novelty: :skip` (for an UNATTENDED writer whose drafts nothing
   would review), which creates NOTHING and returns `:skipped_low_novelty` with the near-neighbor
   (`skip_low_novelty/4`, `:538-556`). That skip is decided LAST: an invalid `project_id`, an
   `idempotency_key` match, and an exact active-title collision are all still answered normally
   rather than dropped.
   Two branches that are easy to miss: `:duplicate` **falls through to create** if the canonical
   neighbor vanished between assess and now (`:472-480`), and `:unknown` creates only BY DEFAULT — a
   caller passing `on_gate_unavailable: :skip` gets `{:error, :gate_unavailable}` and nothing is
   created (`:507-513`). The assessor is config-injected (`Loopctl.Knowledge.ProposalGate`, `:462-464`)
   — do not hardcode it.
2. **Hybrid search provenance** — `Loopctl.Knowledge.hybrid_search/3` (`knowledge.ex:8458`).
   `:curated` wins ONLY when a governed curated source's **absolute** (never pool-relative) confidence
   (`absolute_score/1`, `:8546-8551`) clears a scale-matched threshold AND beats the best retrieved
   candidate by a margin (`hybrid_curated_threshold_and_margin/1`, `:8597-8607`; the pure decision is
   `resolve_provenance/4`, `:8650-8662`) AND is authoritative (not superseded/conflicted — the caller
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
5. **Heat must not rank on a signal heat produces** — `Knowledge.heat_index/2`
   (`knowledge.ex:9088`; the counted set is `@heat_read_access_types`, `:8969`). The heat index is the one retrieval route that
   takes NO query, so its misses are uncorrelated with embedding similarity — which is worth nothing
   if its ordering is something a caller or the route itself generates. It has been violated FOUR
   times, each differently — and once by a FIX for one of the others — so treat any new input to
   the ranking as guilty until checked:
   - **#563** counted `search`/`context` — one row per RESULT of a ranked query, so heat became a
     tally of past ranker output and re-coupled to the embedding similarity it exists to escape.
   - **#567** counted raw event rows, so one key could pin its own article with a `knowledge_get`
     loop; then counted DISTINCT KEYS, which under v2's per-dispatch ephemeral keys counted
     DISPATCHES. A reader is `coalesce(k.agent_id, e.api_key_id)`, and ties break on distinct read
     DAYS — never `count(e.id)`, which hands the tie straight back to the counter a loop inflates.
   - **#569** counted the hop `knowledge_progressive_drill` makes FROM this index — the tool its
     own `meta.drill` names — so being SHOWN produced the rank that showed it. Every drill now
     records the uncounted `drill` type. Derive that label from the READ PATH, never from a
     caller-declared origin — a declaration binds only the clients that send it, and an older
     MCP release or a raw HTTP call then re-opens the loop.
   - **#572** was #569's own fix, half-applied. It exempted tenant articles only: a system
     canonical's drill stayed COUNTED, because `get_article/3` filtered on `tenant_id` and the
     drill was the sole path to a canon body, so excluding it would have frozen every canonical
     at heat 0. Sound about the canon, wrong about the index — ranking a counted class against
     an uncounted one means one `heat` column measures two different things, and since drilling
     is the DOCUMENTED path, following the docs raised only canonicals, self-reinforcingly.
     `get_article/3` resolves canonicals now, so the canon has a caller-named read of its own.
     **The corollary, and the reason this keeps recurring: never rank counted and uncounted
     read paths on one number.** When an item lacks an uncounted-origin read path, give it one
     — do not count the loop it already has.
   `drill` still counts in `RetrievalMetrics.compute_followed_through/2`, which asks whether a body
   was DELIVERED. The two access-type sets diverge on purpose; do not unify them. Adding a value to
   `ArticleAccessEvent.@access_types` requires the same value in `Analytics.@valid_access_types` —
   there is no DB CHECK, those two allowlists ARE the enforcement.

## Ranking changes are gated by the golden-question eval (#469)

Any change to `search_combined/3` ranking (weights, fusion, recency/authority) must ship with a
delta from `mix loopctl.retrieval.eval` — recall@k / MRR / nDCG against the committed golden set
(`priv/retrieval_eval/golden.jsonl`) and baseline (`priv/retrieval_eval/baseline_v1.json`). The
`retrieval-eval` CI job runs it in both the embeddings and keyword-only arms and gates `deploy`.
How to add a labeled question, re-baseline, and read the per-question winners/losers table:
`docs/runbooks/retrieval_eval.md`. Its semantic lane is a SYNTHETIC (provider-free) stand-in —
a regression instrument, not an absolute quality score.

## Latency & observability — the semantic-search hot path

Ranking quality is gated above; this is the LATENCY side. Semantic search / novelty / suggest-links
are the latency-critical path — the #172 full-corpus-scan incident is why the read SHAPE, not the
number, is the load-bearing invariant. To monitor and keep it healthy over time:

- **Metric.** Prometheus histogram
  `loopctl_heavy_read_repo_query_duration_bucket{endpoint="semantic_search"}` (buckets ms
  10/50/100/250/500/1000/2500/5000/10000; siblings `vector_search`, `memory_recall`), defined in
  `lib/loopctl_web/telemetry.ex`, scraped by Fly managed Prometheus off the internal port 9568
  (`/metrics`). Metrics table + no-leak label rules: `docs/runbooks/knowledge-scale.md`.
- **p95:** `histogram_quantile(0.95, sum by (le) (rate(<bucket>[24h])))`. Fly Prometheus auth is the
  FlyV1-token-not-Bearer gotcha — wiki `6dd01e58`.
- **Low-traffic caveat (READ THIS before trusting a p95).** Prod serves ~2 semantic searches/hr, so
  ANY window's p95 is dominated by the occasional cold-cache / autostop-resume outlier on the 512MB
  machines — one cold query swings it by seconds. Read p50 AND the bucket distribution, never the
  sparse p95 in isolation. The CI plan-shape gate is the real regression gate; the prod p95 is an
  observation, not a pass/fail number.
- **Plan-shape invariant (the actual gate).** The request-path inner ANN
  (`Knowledge.semantic_side_table_pool_query/4`) stays filter-after-ANN: a pure index-ordered top-k
  over `article_embeddings` on the per-dimension index (`article_embeddings_hnsw_dim_<dim>_idx`), with
  NO join or distance predicate inside it (wiki `bd4a26b6`; #172). CI asserts this on a seeded corpus
  without `enable_seqscan=off` (`test/loopctl/knowledge/embedding_dimension_plan_scale_test.exs`,
  US-41.1 AC-41.1.12(i)). Re-check prod with `AdminRepo.explain(:all, Knowledge.semantic_side_table_pool_query(...))`
  via `fly ssh console -a loopctl -C "/app/bin/loopctl rpc ..."` — the plan MUST show
  `Index Scan using article_embeddings_hnsw_dim_<dim>_idx`, never a Seq Scan reaching the vector relation.
- **Read-routing flag.** `SystemConfig "embedding_side_table_reads"` (read via
  `Embeddings.side_table_reads_enabled?/0`) routes reads to the dimension-tagged side table vs the
  legacy `articles.embedding` column. Flipping it is a single reversible `SystemConfig.put/2`;
  changes reach every node within 60s via the per-minute `SystemConfigRefreshWorker`. The side table
  is a NARROW relation (the ANN fetches only `article_id` from a lean heap), so it reads measurably
  FASTER than the wide legacy column at equal recall — adding the relation IMPROVED latency, it did not
  cost it. Cutover prod EXPLAIN + p95 artifact: GH #464.
  Production resolves the decision through `Loopctl.Embeddings.ReadPathBehaviour` (default impl
  `Loopctl.Embeddings.SystemConfigReadPath`, which also owns the flag-key string); `config/test.exs`
  points it at `Loopctl.MockEmbeddingReadPath`. **Tests must stub that mock per-process**
  (`Loopctl.DataCase.stub_embedding_read_path/0`, called for you by `stub_all_defaults/0`) and must
  NEVER write the flag — it is `:persistent_term`-cached VM-globally, so a write leaks across the whole
  node. `Loopctl.ConfigEmbeddingReadPathTest` fails the build on a second writer and on any
  `:embedding_read_path` config outside `config/test.exs`.
- **Bulk (re)embed / backfill is a live-DB hazard.** Unthrottled it 504s the live wiki — per-row HNSW
  index maintenance saturates the small Fly Postgres and starves concurrent heavy-read searches past
  their `statement_timeout`. Throttled id-range keyset pattern: wiki `7a4187fd`.

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
