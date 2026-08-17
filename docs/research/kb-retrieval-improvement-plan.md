# KB retrieval improvement plan (2026-08-17)

Why this exists: on 2026-08-17 the question "did KB usage improve?" was answered with
measurement rather than impression, and the answer was **no — it declined**. This note
records what was measured, what the outside research says to do about it, and the ordered
plan derived from both. It is a research note in the `docs/research/` sense: the reasoning
outlives whichever of these techniques we end up keeping.

## 1. What was measured

Source: `article_access_events` (back to 2026-04-10), `search_events`,
`retrieval_metric_snapshots`, `article_links`, `consolidation_proposals`.

| Signal | Value |
|---|---|
| Deliberate reads/week | 414 (wk of Jul 6) → **147** (wk of Aug 10) |
| Results-surfaced → read conversion | 5.18% → **1.67%** (denominator stable at 4.5–5.5 results/search) |
| Published articles EVER deliberately read | **1,443 of 79,074 — 1.8%** |
| Share of search traffic that is machine-injected | **71%** (`memory_recall`, 1,053 of 1,486 calls) |
| Share using the richer entrypoints | **1.1%** (hybrid 15, progressive_index 1, heat_index 0, context 1) |
| Graph edges | 525,932 over 79,074 articles (~6.6/article); 92% have inbound links |
| Edge types | `relates_to` 502,315 (**96%**), `potential_conflict` 23,617 |

Two framings that matter more than any single number:

- **The injected channel is the product.** 71% of traffic is the recall hook, by design —
  the owner's position is "I don't wait for agents to become curious." So the retrieval
  surface that matters is the one that fires unprompted, and its follow-through (5–13%) is
  the headline metric, not agent-initiated search volume.
- **We are not short of edges. We are short of reads.** The graph is healthy. The corpus is
  read at 1.8%. Whatever is wrong is on the retrieval/consumption side, not the linking side.

## 2. What the research says

### Outside the KB

- **The collector's fallacy** (PKM literature; Matuschak, *Collecting material feels more
  useful than it usually is*). The failure mode is a mismatch between **capture velocity and
  synthesis bandwidth** — a bias that equates saving with learning. This names our 79k/1.8%
  directly, and it is a *policy* problem, not a retrieval one.
- **Contextual Retrieval** (Anthropic). Prepend 50–100 tokens of chunk-specific context
  before embedding and before BM25 indexing: **up to 49% fewer failed retrievals**, and
  **up to 67% when combined with reranking**. Prompt caching makes the generation step ~90%
  cheaper.
- **Two-stage retrieval / cross-encoder reranking.** Consistently improves top-k relevance;
  it is the multiplier on the number above, not a substitute for it.
- **GraphRAG.** Wins on multi-hop, global and sensemaking questions (Recall@5 73.4% → 87.8%
  on multi-hop benchmarks); loses to plain vector search on single-fact lookups. The
  consensus recommendation is **route by query shape or fuse both** — vector search to find
  the neighbourhood, graph traversal to expand context.
- **A-MEM** builds a Zettelkasten-style agent memory where each new memory links to related
  ones **and updates existing notes as new information arrives.** This is independent
  validation of Karpathy's ripple-on-ingest rule, implemented in a real system.
- **Cascading entity resolution** (rules → ML → LLM) is the standard cost/accuracy ladder
  for deduplication at scale. We currently stop at the first rung (cosine + title
  normalization).
- **RAG evaluation** needs at least one **retrieval-stage** and one **generation-stage**
  metric: "tracking only generation hides retrieval regressions; tracking only retrieval
  misses fabrication."
- **Cautionary counter-example.** Temporal-knowledge-graph memory (Zep/Graphiti) reports
  memory footprints of ~600k tokens per conversation against Mem0's ~1,764, with
  immediate post-ingestion retrieval failing until background graph processing completes.
  Vendor benchmarks each show the vendor winning. Treat every number above as a hypothesis
  to test here, not a result to adopt.

### Inside the KB

- Karpathy's **LLM-WIKI** nine rules (`aef099c3`), whose June gap analysis of this KB is now
  largely closed: lint exists, consolidation exists, MOC/index exists, the graph is linked.
  Still open from that list: **#5 ripple-on-ingest**.
- **`99a576d3` — "Injected recall must ship its own usage guide and a hard search budget"**,
  and its load-bearing lesson: *a retrieval surface's adoption is a prompt-engineering
  problem, not only a relevance problem. **Better ranking does not help an agent that never
  issues the second query.*** This is why prompt work is ordered ahead of ranking work below.

## 3. The plan

**The governing constraint: we already have an evaluation harness**
(`mix loopctl.retrieval.eval`, `priv/retrieval_eval`, recall@k / MRR / nDCG / answered@k with
committed baselines and a CI gate). So every phase below is an **experiment with a
pass/fail**, not a belief. A technique that does not move the eval does not ship, however
well it is regarded elsewhere.

Ordered by evidence-backed leverage, and by the rule that prompt work precedes ranking work.

### Phase 1 — The injected recall block *(routed: claude-config#312)*
*(still worth doing, but demoted below Phase 2 by the query-length measurement)*
Give the auto-injected block a trigger condition, tool routing by question shape, and a call
budget with a stop rule. Highest leverage because it is the channel that actually fires, and
cheapest because it is prose in a cacheable prefix.
**Check:** `search_follow_through` and surfaced→read conversion vs the baseline in §1, two
weeks after landing.
**Not in this repo** — `block-foreign-config-write.sh`; tracked as claude-config#312.

### Phase 2 — Fix the injected QUERY, before anything downstream of it
*(promoted above the eval work on 2026-08-17 by the measurement below — see §3.1)*

The recall hook builds its query as a stop-word-stripped keyword bag from the user's prompt
wording, producing queries like `infra`, `remove well`, `claude-config`, `yes schedule job
weekly`. **46% of all searches carry <= 2 terms.** Follow-through by query length, joined
through `search_events.search_id` -> `article_access_events.metadata->>'search_id'`:

| query terms | searches | followed through | rate |
|---|---|---|---|
| <= 2 | 675 | 6 | **0.9%** |
| 3-5 | 165 | 4 | 2.4% |
| 6-9 | 495 | 88 | 17.8% |
| 10+ | 120 | 55 | **45.8%** |

Controlled for tool (the 10+ bucket is dominated by deliberate `hybrid_search` calls, which
would convert better regardless), the effect survives **within `memory_recall` alone**:
1.4% / 2.5% / 15.2% across the first three buckets — an 11x spread, with 44% of the hook's
searches in the worst one.

A two-term query cannot be rescued by any ranker, any embedding, or any prompt guide. This
is upstream of every other phase and is why they are all sequenced behind it.
**Check:** median query_terms for `memory_recall` above 6, and the <= 2-term share below 10%;
then re-measure follow-through.
**Not in this repo** — the hook lives in claude-config; folded into claude-config#312.

### Phase 2b — Extend the eval set before changing retrieval
The current eval is the only thing that can adjudicate phases 3–5, so it must first be
representative of what the injected channel actually asks. Harvest real queries from
`search_events` (1,486 available), label the ones the recall hook issued, and grow the eval
set from those rather than from hand-written questions.
**Check:** eval set covers the observed query distribution; baseline regenerated and committed.

### Phase 3 — Contextual embeddings for atomic notes
An atomic note extracted from a book or video loses the context of its source. We partially
compensate today with a title suffix (`— Blackmagic_Converters_Manual`), which is why this is
an experiment and not an obvious win: measure whether prepending a generated
source/hub context before embedding beats what the suffix already buys.
**Check:** recall@5 and answered@5 vs baseline. Ship only on a positive delta.

### Phase 4 — Reranking
Two-stage retrieval over the top-N candidates. The literature's 67% figure is *combined with*
Phase 3, so it is sequenced after it. Cheapest viable implementation is an LLM reranker over
the existing BYO-key `Loopctl.LLM` plumbing — no new vendor — but it puts an LLM call on the
recall path (~200/day), so cost is part of the experiment, not an afterthought.
**Check:** nDCG@5 and answered@5 vs baseline; measured cost per recall.

### Phase 5 — Use the graph at retrieval time
We hold 526k edges and traverse none of them when answering. The research says vector-for-
neighbourhood plus graph-for-expansion beats either alone on multi-hop questions. Start with
one hop of `relates_to` expansion on the retrieved set (progressive_index already does a
limited version of this for hubs).
**Check:** improvement concentrated on multi-hop eval questions; no regression on single-fact
ones — the research is explicit that graph retrieval *loses* on those.

### Phase 6 — Ripple-on-ingest
Karpathy #5, validated by A-MEM. On capture, update the neighbour articles a new source
extends or contradicts, instead of only appending a new node and its links.
**Check:** neighbour-update rate per ingest; no growth in the duplicate-capture proposal rate.

### Phase 7 — Cap the collector's fallacy
The 1.8% read rate is a capture-policy problem and cannot be fixed by retrieval. Decide a
harvest budget and a promotion bar for what may enter the published corpus at all.
**Owner decision, not an engineering one** — recorded here because the preceding phases will
otherwise be asked to compensate for it and cannot.

## 4. Deliberately not doing

- **Typed link taxonomy over the 96% `relates_to` edges.** Attractive (Zettelkasten's value
  is in typed links) but it is a large reclassification of half a million edges with no
  evaluation that would show it working. Revisit if Phase 5 shows graph expansion helping
  and the untyped edges are what limits it.
- **A temporal knowledge graph layer.** The measured footprint and post-ingestion retrieval
  lag reported for that architecture are worse than what we have. Revisit only against a
  concrete multi-hop-over-time failure we can point at.
- **A human approve/reject queue for anything.** #605 settled this: a queue whose only
  consumer is a human nobody staffs is the failure this codebase has already hit four times.

## 5. Status

- Phase 1 — routed, claude-config#312 + `handoff:claude-config#312`.
- Phase 2 — MEASURED (see the table above) and folded into claude-config#312; not yet fixed.
- Phases 2b–7 — not started.

### 3.1 What the ordering cost us to learn

The first version of this plan led with the prompt guide (Phase 1) and put the eval work
second. Following it methodically is what produced the query-length measurement, and that
measurement demoted the plan's own top item. Recorded because the lesson generalises: the
cheapest phase in a retrieval plan is usually the one that measures what the system is
actually being asked, and it belongs first even when a more interesting fix is available.
