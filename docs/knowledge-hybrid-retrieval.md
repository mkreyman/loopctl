# Knowledge Wiki — Hybrid (Curated + RAG) Retrieval (Epic 31)

Authoritative reference for loopctl's **hybrid knowledge retrieval interface**: a
single entrypoint that prefers a **governed curated** answer when one genuinely
answers a query, else falls back to semantic/keyword **retrieval** — returning
**provenance** (`:curated` | `:retrieved`) on one uniform shape so a caller never
branches on "RAG-or-curated." This sits INSIDE the Knowledge Wiki layer (it does
not add a fourth agent-information surface) — see
[the three-layer model](#the-three-layer-model-knowledge-wiki-vs-agent-memory-vs-context-retriever)
below for how it relates to Agent Memory (Epic 28) and the Context Retriever
(Epic 30).

> loopctl is **agent-native**: there is no web UI for hybrid search. Every call is
> an API/MCP call made by an agent under its own key.

---

## Why this exists (the harvested failure)

A confidently-wrong RAG answer is worse than an honest miss: a semantically-near
chunk that does NOT actually answer the query, returned with no signal that it's
"just retrieval," gets trusted as if it were authoritative. The canonical example
(the "refund policy" case this epic's terminal test proves): a tenant has a
governed, curated refund-policy article, but an unrelated "shipping timelines"
chunk sits nearby in embedding space. A naive RAG search can surface that
unrelated chunk with high confidence. `hybrid_search/3` prevents this two ways:

1. It checks for a genuinely-answering **curated** source FIRST, using an
   **absolute** (never pool-relative) confidence score, so a curated doc doesn't
   win just because it's the only thing in a sparse pool.
2. When curated does NOT clear the bar, it falls through to ordinary retrieval and
   is HONEST about it — `meta.provenance == :retrieved` tells the caller this is
   RAG, not a governed answer.

Both branches return through the same function, same map shape, same field names
— a caller reads `meta.provenance` and nothing else changes.

---

## The resolution rule

`Loopctl.Knowledge.hybrid_search(tenant_id, query_string, opts \\ [])` composes
the ALREADY-SHIPPED `search_combined/3` (retrieval: semantic + keyword, US-shipped
pre-epic-31) and `list_curated_sources/2` (curated identification, US-31.1) into
one resolution layer. It does not re-architect either.

`:curated` wins iff **ALL** of:

1. The curated candidate's **absolute** confidence score clears an absolute
   threshold for its own scale:
   - Semantic (cosine similarity, `1 - cosine_distance`, already `0..1`):
     `:knowledge_hybrid_curated_threshold`, default **0.75**.
   - Keyword-only (a bounded `raw / (raw + 1)` transform of `ts_rank_cd`, which is
     otherwise unbounded — a short, title-exact match empirically exceeds 2.0):
     `:knowledge_hybrid_curated_threshold_keyword`, default **0.5**.
2. It beats the best NON-curated candidate's absolute score by a margin:
   `:knowledge_hybrid_curated_margin` / `_keyword`, both default **0.1**.
3. It is **authoritative** — published, not superseded, not part of an open
   `:potential_conflict` link (enforced by `list_curated_sources/2`, US-31.1;
   `Knowledge.authoritative_curated?/1` is the pure per-article check).

Otherwise the response is `:retrieved`, even if a curated doc is technically in
the pool — a near-but-wrong curated doc that is semantically close but below
threshold, or that loses the margin check against a stronger retrieval result,
NEVER wins `:curated`.

### Why absolute, not pool-relative, scoring

`search_combined/3`'s own `:final_score` is **min-max normalized** across the
current pool — a lone or top candidate in a sparse pool always normalizes to
`1.0` regardless of its TRUE similarity. Using that score for the curated
decision would let a curated doc that barely relates to the query win at
"confidence 1.0" simply because nothing else was in the pool. `hybrid_search/3`
instead scores every candidate via `absolute_score/1`, reading the RAW
`:similarity_score` (semantic) or a bounded transform of the raw
`:relevance_score` (keyword) — a value computed independently of pool
composition. Cosine similarity and normalized `ts_rank_cd` are **different,
incommensurable scales**; the threshold/margin PAIR used is selected to match the
winning curated candidate's own scale (never compared cross-scale).

### Resolved over the full ranked pool, not the caller's page

The decision is made over the FULL ranked candidate pool (same cap
`search_combined/3`'s own sub-searches already use), independent of the caller's
`:limit`/`:offset`. A curated source ranked outside the requested page is still
found and scored. When `:curated` wins, the winning article is hoisted to the
FRONT of the pool BEFORE pagination, so `meta.provenance == :curated` always
means `results |> List.first()` (at `offset: 0`) IS that curated answer — never a
decoy that merely out-ranked it on the pool-relative `:final_score`.

### The pure decision function

`Knowledge.resolve_provenance(curated_score, best_retrieved_score, threshold,
margin)` is the single, unit-testable rule behind the above:

```elixir
def resolve_provenance(nil, _best_retrieved_score, _threshold, _margin), do: :retrieved

def resolve_provenance(curated_score, best_retrieved_score, threshold, margin) do
  if curated_score >= threshold and curated_score - best_retrieved_score >= margin do
    :curated
  else
    :retrieved
  end
end
```

`threshold`/`margin` must already be scale-matched by the caller
(`hybrid_curated_threshold_and_margin/1` does this internally) — the pure
function does no scale reasoning of its own.

---

## The uniform shape / no-caller-branching contract

```elixir
{:ok, %{results: [map()], meta: map()}} = Knowledge.hybrid_search(tenant_id, query, opts)
```

`meta` is `search_combined/3`'s own meta (search_mode, fallback, keyword_only,
limit, offset) merged with exactly:

| Field | Meaning |
|-------|---------|
| `provenance` | `:curated` \| `:retrieved` |
| `confidence` | The WINNING candidate's absolute score for its OWN provenance class. `0.0` when there are no results, or `:retrieved` won with no genuine non-curated competitor. **Never** a rejected candidate's score from the OTHER class (`:retrieved`'s confidence is never a below-threshold curated score). |
| `curated_article_id` | The winning curated article's id when `provenance == :curated` (guaranteed present AND first in `results`); `nil` on `:retrieved`. |

**Both branches return the identical map-key set** — on `results` (per-item keys
are identical by construction; `:curated` reorders the same ranked pool rather
than re-filtering it) and on `meta`. A caller reads `meta.provenance` and
`meta.curated_article_id`; it never needs to know which subsystem (curated lookup
vs `search_combined/3`) actually produced the answer. This is the literal fix for
#305's "no caller-side RAG-or-curated branching."

### Degradation honesty

`hybrid_search/3` does not re-implement embedding degradation — it reuses
`search_combined/3`'s. When embeddings are unavailable, the pool falls back to
keyword-only (`meta.fallback: true`, `meta.search_mode: "keyword_only"`), and the
curated candidate's absolute keyword-scale score is compared against the
KEYWORD threshold/margin: a curated source still confidently identifiable by
keyword can win `:curated` under degradation; a merely-incidental keyword hit
falls to `:retrieved`, same as a weak semantic match would. Never a silent empty,
never a false `:curated` under degraded matching.

### Tenant isolation

`tenant_id` is threaded into BOTH `search_combined/3` (retrieval) and
`list_curated_sources/2` (curated identification) — both run on `AdminRepo`/
`HeavyRead` (BYPASSRLS). **RLS does not backstop these reads.** The explicit
`tenant_id` predicate in each function is the sole isolation boundary — assert it
by test, never assume it.

### System-scoped curated sources

A `scope: :system` curated article (tenant_id `nil`, curated via
`mark_curated(nil, article_id, scope: :system, ...)`) participates in EVERY
tenant's curated pool as a fallback — but a tenant's OWN curated answer on the
same topic always wins over the system canonical (system never overrides a
tenant's own). If the tenant's own curated answer on that topic is itself in an
open conflict, it is excluded (per the authoritative check) — and the system
canonical on that SAME topic is still suppressed too (a disputed topic never
silently falls back to the generic system answer; the conflict must be resolved
first). See `test/loopctl/knowledge_curated_test.exs` "system-scope precedence"
for the full matrix.

### Conflicted / superseded curated articles

`list_curated_sources/2` excludes a curated article that is `:superseded` or
part of an OPEN `:potential_conflict` link from the authoritative pool entirely
— such an article can never win `:curated` through `hybrid_search/3`, and the
conflict is never silently resolved in the caller's favor; it must be resolved
through the normal conflict-resolution path (`knowledge_resolve_conflict`)
before the article can be authoritative again.

---

## Progressive disclosure (US-31.3)

Two-step retrieval to bound the tokens returned per query:

1. **Index** — `Knowledge.progressive_index(tenant_id, topic, opts)` /
   `GET /api/v1/knowledge/progressive_index?topic=...` — returns `<=` a
   configurable top-K (`Knowledge.progressive_top_k/0`) of COMPACT stubs
   (`id`/`title`/`category`/`summary` — never a `body`). The seed is
   `search_keyword/3` over `topic`, enriched by one hop of `:relates_to`
   article-link traversal from any "hub" article (an article whose outgoing
   `:relates_to` degree clears `Knowledge.min_hub_relates_to/0`), capped per-hub at
   `Knowledge.max_graph_neighbors_per_node/0`. Curated matches are ordered ahead
   of non-curated matches for the same topic (AC-31.3.4).
2. **Drill** — `Knowledge.progressive_drill(tenant_id, article_id)` /
   `GET /api/v1/knowledge/progressive/:id` — fetches the FULL body of one stub the
   caller chose from the index. Tenant-scoped (a foreign tenant's article id is a
   clean `{:error, :not_found}` / 404, including for a system-scope article's
   draft/archived guard).

**Known lexical-omission caveat** (documented honestly, not swept under the rug):
the index's seed step is a `tsquery` match against `topic` — a fuzzy or
paraphrased query can miss a topically-relevant curated article that shares no
lexical tokens with the seed text, even though `hybrid_search/3`'s semantic pool
would have found it. Progressive disclosure is a keyword-first navigation aid
over the corpus, not a substitute for `hybrid_search/3`'s semantic resolution —
use `hybrid_search/3` when you need the governed provenance decision, and
progressive disclosure when you want to browse/enumerate a topic cheaply.

Do NOT use the OKF full-tenant export (`index.md`) for this purpose — it is a
private, full-corpus artifact, not the progressive-disclosure seed.

---

## Surfaces

| Operation | Context (`Loopctl.Knowledge`) | HTTP API | MCP tool |
|-----------|-------------------------------|----------|----------|
| Hybrid search | `hybrid_search/3` | `POST /api/v1/knowledge/hybrid_search` | `knowledge_hybrid_search` |
| Progressive index | `progressive_index/3` | `GET /api/v1/knowledge/progressive_index` | `knowledge_progressive_index` |
| Heat index | `heat_index/2` | `GET /api/v1/knowledge/heat_index` | `knowledge_heat_index` |
| Progressive drill | `progressive_drill/3` | `GET /api/v1/knowledge/progressive/:id` | `knowledge_progressive_drill` |

All of these endpoints render at `GET /swaggerui` (loopctl's self-documenting
OpenAPI 3.0 surface) alongside every other API route.

### The heat index is the one route that takes no query (#554, #567)

Hybrid search and the progressive index both begin from a QUERY, so they share a
failure mode: a paraphrase, or material topically central but lexically
dissimilar to the question, comes back empty — and an empty result reads as *"the
KB has nothing"* rather than *"I asked badly"*, with nothing in the payload to
contradict it. `heat_index/2` takes no query at all, so its misses are
uncorrelated with embedding similarity. Reach for it when a search came back
empty or thin, or before you know what to ask.

Ordering is **usage, not relevance**: the number of DISTINCT READERS —
`coalesce(agent_id, api_key_id)` of the key that read — that opened each article
inside `meta.heat_window`, ties broken by distinct read DAYS before the article
id — never by raw read count, which is the one counter a loop inflates.
Distinct readers rather than
raw reads is a correctness property, not a refinement — counting event rows let
any agent pin its own article at rank 1 by calling `knowledge_get` in a loop, and
because this index is meant to be pasted into a cached prefix, that ranking then
propagated into every other agent's context. It is the AGENT, not the key row:
v2 mints a fresh ephemeral key per dispatch, so counting keys would count
dispatches and re-open the same pinning. Only `get`-shaped reads count.
`search` and `context` write one row per RESULT of one ranked query, so counting
them would re-couple this route to the embedding similarity it exists to be free
of. `drill` is excluded for a different reason (#569): a drill IS a genuine
single-article body read, but `knowledge_progressive_drill` is the tool this
index's own `meta.drill` names, so counting it closed a loop — the index showed an
article, a caller drilled it *because* it was shown, and the drill fed the rank
that showed it. Material that never surfaced could not overtake material that
already had. The general rule behind all three exclusions: **heat must not rank on
a signal heat produces.**

Only the hop *from this index* is excluded, and only when the caller declares it
(`from=heat_index` on the drill). A drill that follows `progressive_index/3` is an
ordinary caller-chosen read and records a `get`; so does a drill of a published
system canonical, whose body has no other read path — labelling every drill as an
index drill left the canon unrankable and silenced topic-seeded reads. The
declaration is cooperative, so an undeclared drill or a plain `knowledge_get` of a
listed id still counts; what bounds a *deliberate* manipulation is the
distinct-reader count, not this label.

`drill` still counts as follow-through in
`RetrievalMetrics.compute_followed_through/2`, which asks a different question —
was a body *delivered* after a search. The two access-type sets diverge on
purpose and must not be unified.

The window is snapped to a UTC day boundary, so two calls with no intervening read
return a byte-identical payload — which is what makes it safe in a cached prefix.
The snap always NARROWS: an explicit `since` is never widened back — one inside
the current UTC day is used exactly as given, since its next boundary has not
happened yet. It defaults to 90 days and is clamped to at most 365 days of
lookback and to no later than today; `meta.heat_window` always echoes the window
actually used.

Drill a heat stub with `progressive_drill/3`, **not** `get_article/3`: the heat
index also lists published system canonicals, whose `tenant_id` is NULL, and
`get_article/3` filters on `tenant_id`. `meta.drill` states this in the payload.

`hybrid_search/3`'s `opts` forward directly to `search_combined/3`:
`:keyword_weight`, `:semantic_weight`, `:project_id`, `:category`, `:status`,
`:tags`, `:limit`, `:offset`, `:api_key_id` (attribution). Errors
(`{:error, :invalid_weights}`, `{:error, :empty_query}`,
`{:error, atom(), String.t()}`) propagate unchanged from `search_combined/3`.

---

## The three-layer model: Knowledge Wiki vs Agent Memory vs Context Retriever

Hybrid retrieval is a **capability of the Knowledge Wiki layer** — it does not
add a fourth surface. The three layers (full references:
[`docs/agent-memory.md`](agent-memory.md),
[`docs/context-retriever.md`](context-retriever.md)):

| Layer | What it holds | Scope / owner | Lifecycle | Reach it via |
|-------|---------------|---------------|-----------|--------------|
| **Knowledge Wiki** (incl. hybrid retrieval) | Curated, *shared* tenant knowledge — patterns, decisions, findings, references (documents). Hybrid search prefers a governed **curated** answer, else falls back to semantic/keyword **retrieval**, on one uniform shape with `provenance`. | Tenant (with per-article agent visibility) | Human/agent-curated, versioned, linked, conflict-resolved | `knowledge_*` tools / `/api/v1/knowledge*` |
| **Agent Memory** | An agent subject's *private* working memory — session turns + long-term facts about *its* work | `(tenant, subject_id)` — one agent | Append/embed/supersede/forget; session tier expires | `memory_*` tools / `/api/v1/memory*` |
| **Context Retriever** | *Governed, structured* access to *live business data* (rows, not documents) | Tenant, schema-scoped | Read-through over the operational store; entity definitions are admin-authored | `retrieve_*` tools / `/api/v1/entities*` + `/api/v1/retrieve/*` |

Rule of thumb, extended for hybrid search: *asking a question that MIGHT have a
governed answer, and you want to know whether the answer is authoritative or "our
best guess"?* → `knowledge_hybrid_search` (reads `meta.provenance`). *Just
browsing/enumerating a topic cheaply?* → `knowledge_progressive_index` +
`knowledge_progressive_drill`. *A query-shaped route came back empty, or you
don't yet know what to ask?* → `knowledge_heat_index` (no query, so its misses
are uncorrelated with the ones that just failed you). *A fact only you need to
recall about your own work?* → `memory_remember`. *A live structured row (a
story, a project)?* → `retrieve_*`.

---

## #305 / #306 — same feature, and the "reconcile cole-medin doc" item

GitHub issues **#305 and #306 describe the SAME feature** (the OKF-curated + RAG
hybrid knowledge interface this epic implements). **Recommendation: close one as
a duplicate of the other** — do not auto-close either; a human/orchestrator with
issue-write access should pick which stays open and link the other as
`Closes #<n>` on this epic's merge.

The "#305 reconcile `docs/cole-medin-self-evolving-wiki.md`"-style follow-up item
is the SAME reconciliation epics 28/29/30 already completed: the retired note was
removed in PR #310 and its durable content lives in the KB hub (`fb9abd73`/
`3ee5f890`) and in `docs/agent-memory.md` / `docs/context-retriever.md` (and now
here). No parallel/duplicate doc exists for hybrid retrieval — this file is its
single home.

---

## Verification (US-31.5, terminal)

- **End-to-end + negative control** (`test/loopctl/knowledge/hybrid_e2e_test.exs`):
  a governed curated refund-policy article suppresses an unrelated fuzzy chunk
  (`:curated`, the curated article first in `results`); archiving that curated
  article — removing it from the published search pool while leaving the
  unrelated chunk unchanged — flips the result to `:retrieved` and surfaces the
  previously-suppressed chunk — proving the governed answer's presence, not an
  unrelated corpus change, was what suppressed it. A niche, non-curated topic
  falls to `:retrieved`. A near-but-wrong curated doc (below threshold) is never
  mislabeled `:curated`.
- **Shape parity**: the `:curated` and `:retrieved` meta key sets are identical;
  a caller branches on `meta.provenance` alone.
- **Tenant isolation across every surface** (context, progressive index/drill,
  HTTP API): no tenant A content is reachable via a tenant B key on any surface.
  A system-scoped curated article participates without overriding a tenant's own
  curated answer. A superseded / open-conflict curated article is never returned
  as authoritative without the conflict being surfaced.
