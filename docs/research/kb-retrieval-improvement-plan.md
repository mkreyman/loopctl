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
| Share of search traffic that is machine-injected | **71%** (`memory_recall`, 1,053 of 1,486 calls) — but see §2.1: a further ~11% is smoke/canary traffic, so filter `client_entrypoint` |
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

## 1.1 What this repo's own runbook already said, and this plan under-weighted

`docs/runbooks/search-events-analysis.md` predates this note and contains three warnings that
bear directly on it. They were not consulted before §1 was written, which is how the confound
in §2.1 survived — the segmentation trap is documented there in step 2.

- **Follow-through is a FLOOR, not a satisfaction rate.** "An agent whose question is answered
  by the snippet correctly opens nothing, and that is a success this metric scores as a
  failure." The injected block renders a title and snippet per row, so an agent that reads the
  snippet and needs no more is indistinguishable here from one that ignored it. **This is the
  single largest caveat on the whole plan**: the headline metric cannot separate "surfaced and
  ignored" from "surfaced and sufficient".
- **The documented healthy band is 1–7%, "the biggest number in this area and the least moved
  by anything shipped so far."** The attributed hook channel measures 11.3% (§2.1) — but that
  comparison is only suggestive, and saying so is the point of §2.1: the runbook does not state
  its attribution rule, and 11.3% is an UPPER bound (the cross-key rule it requires is
  confounded whenever the deliberate channel surfaced the same article). Two follow-through
  numbers computed under unstated rules are not comparable, which is exactly the mistake this
  note already made once. What survives is the weaker, sufficient claim: **there is no
  measurement here showing the injected channel below its historical norm**, so "follow-through
  is collapsing" is unsupported rather than refuted.
- **Step 4, verbatim: "Do not spend a month's work on the retrieval side on the strength of a
  utilization number that was never segmented by origin."** Phases 3–5 are retrieval-side
  work, and §1's numbers were unsegmented. That warning lands on this plan.

Read together with §2.1 and Phase 2b, the case for the retrieval-side phases is weaker than
this note originally made it, and the case for Phase 7 (capture policy) and for better
INSTRUMENTATION — a signal that distinguishes a sufficient snippet from an ignored one — is
stronger. Neither conclusion is reached by argument here; both are what the measurements left
standing.

## 2.1 Correction: how the follow-through numbers were got wrong (2026-08-17)

The first version of this note carried a follow-through-by-query-length table
(0.9% / 2.4% / 17.8% / 45.8%) and drew the plan's ordering from it. **The table was
confounded and is withdrawn.** Re-derived with an explicit, stated attribution rule, the
sound measurement is by CLIENT ENTRYPOINT (1,525 events, 2026-08-12..17):

| entrypoint | tool | searches | avg terms | followed | rate |
|---|---|---|---:|---:|---:|
| `cli` | `knowledge_hybrid_search` | 7 | 13.0 | 6 | **85.7%** |
| `cli` | `knowledge_search` | 150 | 10.8 | 60 | **40.0%** |
| `sdk-cli` | `knowledge_search` | 20 | 9.0 | 6 | 30.0% |
| `hook` | `memory_recall` | 522 | 6.5 | 59 | **11.3%** |
| unattributed | `knowledge_search` | 181 | 3.5 | 6 | 3.3% |
| unattributed | `memory_recall` | 504 | 1.8 | 13 | 2.6% |
| `smoke` | `knowledge_search` | 86 | 1.0 | 0 | 0.0% |

This CONFIRMS §1's "injected follow-through is 5-13%" (it is 11.3% on attributed hook
traffic) and refutes the 11x query-length spread. Length and DELIBERATENESS co-vary here and
this dataset cannot fully separate them; the one comparison holding the tool constant
(`memory_recall`: 1.8 terms -> 2.6%, 6.5 terms -> 11.3%) puts the length effect at ~4x.

### The three traps, because each one produces a plausible wrong number

- **`get`/`context` rows carry NO `search_id`.** Only `access_type = 'search'` rows do (one
  per surfaced result). So the obvious `search_events -> article_access_events` join on
  `metadata->>'search_id'` silently matches only SURFACED rows, and a "followed through"
  column built that way is really "did the search return anything" — which is ~98%
  everywhere. Follow-through has to be inferred: article A was surfaced by search S, and A
  was later read by a `get`.
- **The hook and the session hold DIFFERENT `api_key_id`s.** Measured: the hook's key made
  1,071 recalls and **1** deliberate read ever; the MCP/session key made 0 recalls and 2,535
  reads. So a same-key join reports the injected channel at exactly 0 follow-through — and
  that 0 is **`n/a`, not 0**, the distinction this repo's own eval harness is careful about
  ("`0.0` is 'it ran and retrieved nothing'; `n/a` is 'there was nothing to score'").
  Cross-key attribution is required, and it is confounded whenever both channels surface the
  same article, so isolate articles only ONE channel surfaced.
- **`search_events` carries synthetic traffic.** `client_entrypoint = 'smoke'` is the smoke
  test (86 rows, all 1-term, 0% follow-through by construction), and the canary replays a
  fixed prompt list — visible as distinct queries each appearing exactly 12 times. Together
  with SessionStart's bare-repo-name queries these dominate the short-query buckets, which
  is most of what the withdrawn table was measuring. **Filter on `client_entrypoint` before
  drawing any conclusion.** Also note the table is a rolling ~5-day window, not history.

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

### Phase 1 — The injected recall block *(LANDED: claude-config#314)*
*(briefly demoted below Phase 2 by the query-length measurement; restored when that
measurement was withdrawn — §2.1)*
Give the auto-injected block a trigger condition, tool routing by question shape, and a call
budget with a stop rule. Highest leverage because it is the channel that actually fires, and
cheapest because it is prose in a cacheable prefix.
**Check:** `search_follow_through` and surfaced→read conversion vs the baseline in §1, two
weeks after landing.
**Not in this repo** — `block-foreign-config-write.sh`; landed as claude-config#314.

### Phase 2 — Fix the injected QUERY *(landed: claude-config#314)*
*(promoted above Phase 1 on 2026-08-17, then RETRACTED the same day — see §3.1)*

The recall hook built its query as a stop-word-stripped keyword bag in document order, so a
long prompt was distilled from its opening clause — throat-clearing rather than subject.
`kb_recall_query` now scores every surviving term by salience (repetition, weak-word
penalty, identifier shape, a short-acronym allowlist standing in for IDF) and keeps the best
8 in first-appearance order.

**The measurement that promoted this phase was confounded and its headline does not
survive.** See §2.1 for the sound version and the three traps that produced the bad one.
What holds: query length and follow-through do move together, but the only *within-tool*
comparison available puts the effect at ~4x (2.6% -> 11.3%), not the 11x first reported —
and a well-formed injected query still tops out at 11.3% against 40% for a deliberate one,
so most of the gap this plan is chasing is NOT query construction.
**Check:** median `query_terms` for `memory_recall` above 6, and the <= 2-term share below 10%.

### Phase 2b — Extend the eval set before changing retrieval *(DONE)*
The current eval is the only thing that can adjudicate phases 3–5, so it had to first be
representative of what the injected channel actually asks — every golden question was
hand-authored prose, while 71% of traffic is an 8-term distilled keyword bag.

**Mining real queries turned out to be the wrong instrument, and the reason matters.** The
hook channel follows through on ~2% of what it surfaces, and those few reads are
cross-key and confounded (§2.1), so production traffic cannot supply trustworthy relevance
LABELS at any useful volume. What it can supply is trustworthy query SHAPE. So the eval now
carries a **paired** question instead: golden_v3's `corpus_ref` lets `q-<topic>-kwbag` supply
only its own query text — the real `kb_recall_query` distiller's output for that question,
generated by running it through the production function — and borrow the prose question's
corpus and labels. Identical corpus, identical labels, one variable.

**The result contradicts this plan's Phase 2 premise.** Distillation does not degrade
retrieval; it improves it, in both arms, with six questions up and none down:

| metric | prose (26q) | distilled (26q) | delta |
|---|---:|---:|---:|
| embeddings MRR | 0.7463 | 0.8444 | **+0.0981** |
| embeddings nDCG@5 | 0.7204 | 0.7717 | +0.0513 |
| embeddings answered@5 | 22/26 | 23/26 | +1 |
| keyword_only MRR | 0.1923 | 0.2692 | **+0.0769** |
| keyword_only answered@5 | 5/26 | 7/26 | +2 |

Only the keyword arm transfers: `websearch_to_tsquery` ANDs every lexeme, so dropping five
function words from a 13-word query makes a conjunctive match likelier — real in production.
The embeddings arm is the synthetic random-projection stand-in, and a bag-of-words projection
flatters a bag-of-words query, so read that half as "not harmful", not as a gain.

What this does NOT settle: production hook queries are distilled from CONVERSATIONAL
PROMPTS, not from well-formed questions, so a real one can be about the wrong topic entirely
— a failure no pair here reproduces. **Three hypotheses for the 11.3%-vs-40% gap are now
eliminated (ranking, query length, distillation) and that one is not.**
**Done:** golden_v3 committed with 26 paired questions; baseline regenerated on pg16.

### Phase 2c — Make the injected channel measurable at all *(DONE: #689)*
*(not in the original seven — it fell out of §1.1, which found the headline metric could not
tell success from failure)*

Nothing distinguished "the snippet sufficed" from "the row was ignored", and worse,
`RetrievalMetrics` correlated a search with an open on `api_key_id` — while the injected hook
searches under a DIFFERENT key from the session that reads. So the channel carrying 71% of
volume scored a STRUCTURAL ZERO in the shipped metric, meaning unmeasurable rather than
unread. Reads now carry an origin resolved server-side at write time (never a caller
parameter — an assertable origin is follow-through a caller can manufacture), and searches
are partitioned `opened` / `reformulated` / `quiet`.

**`quiet` is deliberately still ambiguous.** Splitting out `reformulated` removes the one
unambiguous failure from the not-opened bucket; it does not resolve snippet-sufficed vs
ignored, and naming it for the outcome it cannot establish is how a floor gets read as a rate.
**Check:** `cross_key_opens` non-zero on real traffic — i.e. the channel is visible at all.

### Phase 2d — Make plain search legible without a second call *(DONE: #690)*

`snippet` is a `ts_headline` fragment and therefore came ONLY from the keyword lane, so a
result the query did not lexically match — precisely what the semantic lane exists to find —
arrived as a bare title. The rows most in need of an explanatory line were exactly the ones
that had none, and an agent handed a bare title either opens it blindly or ignores it: both
land in the metric above as retrieval's fault. Every result now carries a highlight or a lead
extract, labelled `snippet_source`.

This is the shape of work the owner's constraint calls for — agents are only ever told about
plain search, so anything that makes results judgeable belongs on the server, not in an
agent's tool choice. Phases 3–5 should be read the same way.
**Check:** the injected block's rows are judgeable without a `knowledge_get`; re-measure
`searches_quiet` against `cross_key_opens` once Phase 2c has collected real traffic.

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

- Phase 1 — **LANDED** as claude-config#314 (the injected block now ships a trigger
  condition, a routing table by question shape, and a 3-call budget with a stop rule; the
  usage guide lives in the cached `~/.claude/CLAUDE.md` prefix, not in the per-turn block).
- Phase 2 — **LANDED** as claude-config#314. `kb_recall_query` selects terms by salience
  rather than document order, capped at 8. Its promotion above Phase 1 was retracted the
  same day (§2.1, §3.1); the fix is still worth having, on a ~4x effect rather than 11x.
- Phase 2b — **DONE.** golden_v3 + `corpus_ref` paired questions; baseline regenerated. Its
  result retires Phase 2's premise rather than confirming it (see above).
- Phase 2c — **DONE, deployed v523** (#689), and **verified on real traffic** — see below.
  The injected channel is now measurable instead of scoring a structural zero. One
  contaminant is still open: the recall canary declares `client_entrypoint: "hook"`,
  identical to real traffic, so its fixed prompt list sits inside the new counters. Not
  fixable here (the caller must declare itself, as `smoke.sh` does): handed to
  claude-config#317.
- Phase 2d — **DONE, deployed v523** (#690). Every search result carries a snippet.
- Phases 3–7 — not started, and the ordering has moved on the evidence:
  - **Phase 4 (reranking) is the weakest-motivated of them.** Ranking, query length and
    distillation are each eliminated as the cause of the injected channel's gap, so a better
    ranker improves something no measurement implicates. It should not be started until
    Phase 2c's counters say ranking is the problem.
  - **Phase 3 and Phase 5 are the live engineering candidates**, both because they change
    what is retrievable at all rather than how a fixed candidate set is ordered.
  - **Phase 7 is the owner's call and is unchanged by any of this** — a 1.8% read rate is a
    capture-policy problem and no retrieval phase can compensate for it.
  - **The honest sequencing note:** Phase 2c's whole point is to make phases 3–5 falsifiable
    on production traffic rather than only on a synthetic eval corpus. Starting them before
    it has collected anything would forfeit exactly the check it was built to provide.

### 5.1 First traffic against the new counters (2026-08-17, ~3h post-cutover)

The Phase 2c check was "`cross_key_opens` non-zero on real traffic — i.e. the channel is
visible at all". It **passes**, and the shape is the predicted one:

| entrypoint | searches | searches opened | attribution of the opens |
|---|---:|---:|---|
| `hook` / `memory_recall` | 31 | 2 | 3 reads, **all `cross_key`** |
| `cli` / `knowledge_search` | 6 | 3 | 3 reads, `same_key` |
| `cli` / `knowledge_hybrid_search` | 6 | 2 | 2 reads, `same_key` |
| `smoke`, `session-start` | 24 | 0 | - |

Every hook open is cross-key and every cli open is same-key. That is the diagnosis in §2.1
confirmed from the other direction: the shipped same-key metric could not have counted ONE
of the injected channel's opens, and the zero it reported was `n/a`.

**Three hours is a mechanism check, not a rate**, and no phase ordering should move on it.
The evaluation window is 1-2 weeks from the cutover (2026-08-17T18:00Z), with `smoke` and
`session-start` excluded and the canary contaminant (claude-config#317) resolved first.

The audit also re-ran §3.1's own failure live: the entrypoint segmentation joins
`search_events.search_id`, NOT `search_events.id` — different columns — and the wrong one
returns a clean, plausible, entirely false "0 opens" for every entrypoint. The corrected
query and its integrity check are now in `docs/runbooks/search-events-analysis.md` §3c so the
next person joins the right column instead of rediscovering this.

### 3.1 What the ordering cost us to learn, twice

**First lesson (stands).** The plan led with the prompt guide and put the eval/measurement
work second. Following it methodically produced a query-length measurement that demoted the
plan's own top item. The cheapest phase in a retrieval plan is usually the one that measures
what the system is actually being asked, and it belongs first.

**Second lesson (why that first one was half-right).** Continuing methodically then
invalidated the promotion itself: the query-length table was confounded three ways (§2.1),
and with the confounds removed Phase 1 is back above Phase 2 on the merits. A measurement is
not automatically the sound part of a plan just because it is a measurement — and the
specific failure was reaching for the join that EXISTS (`metadata->>'search_id'`) instead of
the join the question needs, then reading its output as follow-through. Both numbers were
produced by the same person on the same day with the same care; what separated them was
stating the attribution rule out loud, at which point the confound was visible immediately.

Two consequences worth carrying beyond this note:

- **A ratio of two aggregates survived; a per-row join did not.** §1's conversion (5.18% ->
  1.67%) and 1.8%-ever-read numbers were computed as counts over counts and all hold up.
  Every number that needed rows to be MATCHED to each other was wrong. Prefer the aggregate
  when the linking key is not one you can point at.
- **`n/a` is not `0`.** The same-key join said the injected channel converts at 0%, which
  reads as a devastating finding and is merely an unmeasurable one. This repo already
  encodes that doctrine in `RetrievalEval` for exactly this reason; it applies to ad-hoc
  production analysis too.
