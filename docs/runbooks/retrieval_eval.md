# Retrieval eval runbook (golden questions + CI gate)

The retrieval eval is the falsifiability gate for every ranking change to
`Loopctl.Knowledge.search_combined/3`. Without it, a change to weighting, fusion, or
recency scoring is unfalsifiable — it either "feels better" or it doesn't.

```
mix loopctl.retrieval.eval                      # score + compare against the baseline
mix loopctl.retrieval.eval --mode both          # embeddings AND keyword-only arms
mix loopctl.retrieval.eval --fail-on-regression # what CI runs
mix loopctl.retrieval.eval --update-baseline    # re-baseline (both modes)
mix loopctl.retrieval.eval --json               # machine-readable output
mix loopctl.retrieval.eval --cleanup            # reap eval tenants a killed run leaked
```

The task mints a throwaway tenant, seeds the corpus into it, and hard-deletes both on the
way out (happy path AND when the run raises). If a run is KILLED (OOM / SIGKILL / CI
cancel) the `after` never runs, leaking a tenant plus ~100 published, embedded articles;
`--cleanup` reaps every tenant whose slug starts `retrieval-eval-` (deleting its seeded
corpus first). The task also **refuses to run in `:prod`** unless you pass `--allow-prod`
— it writes to and hard-deletes from whatever DB it is pointed at through `AdminRepo`
(BYPASSRLS), and a prod run buys nothing dev/CI does not (the provider lane is synthetic).

## What it does

1. Loads the committed golden set, `priv/retrieval_eval/golden.jsonl`.
2. Seeds every question's labeled corpus into a **throwaway tenant** as published,
   embedded articles.
3. Runs each question through `search_combined/3` and maps the returned article ids back
   to the labels' stable `doc_id`s.
4. Scores **recall@k**, **MRR**, and **nDCG@k**, plus the with-retrieval vs
   no-retrieval headline spread.
5. Compares against `priv/retrieval_eval/baseline_v1.json` and prints a per-question
   table with the delta (winners and losers).
6. Deletes everything it seeded — including the throwaway tenant — on the happy path and
   when the run raises.

Code: `lib/loopctl/knowledge/retrieval_eval.ex` (+ `retrieval_eval/golden_set.ex`,
`retrieval_eval/baseline.ex`, `retrieval_eval/report.ex`) and
`lib/mix/tasks/loopctl.retrieval.eval.ex`.

## The metrics

| Metric | Meaning | Undefined when |
|--------|---------|----------------|
| `recall@k` | Share of a question's relevant docs inside the top k. | The question has no labels. |
| `MRR` | `1 / rank` of the FIRST relevant doc; `0.0` when none is retrieved. | The question has no labels. |
| `nDCG@k` | Graded gain, discounted by `log2(rank + 1)`, normalized by the ideal ordering. | No achievable gain (all grades 0). |
| `answered@k` | Questions with at least ONE relevant doc in the top k — the "17/20" headline numerator. | — |

An **undefined** metric prints and serializes as `n/a` / `null`, never `0.0`. The two mean
different things: `0.0` is "it ran and retrieved nothing"; `n/a` is "there was nothing to
score". A metric that becomes undefined counts as a regression, because it stopped being
computable.

## The two modes

* `--mode embeddings` (default) — keyword and semantic lanes merge.
* `--mode keyword_only` — forces the degraded path by passing
  `embedding: {:error, :no_api_key}`, exactly as production degrades when the embedding
  provider is unavailable.

The report always names the mode it **observed** (read out of the search response's own
`meta.search_mode` / `meta.fallback` / `meta.fallback_reason`), not the mode that was
requested — a run that silently degraded says so, and `mixed` means the questions
disagreed.

The keyword-only arm scores far lower than the embeddings arm — but understand exactly
what it does and does NOT buy before relying on it:

* **It does not exercise fusion.** In `keyword_only` mode the eval passes
  `embedding: {:error, :no_api_key}`, so `search_combined/3` never runs the semantic lane
  and never calls `merge_results`. A fusion change (e.g. reciprocal rank fusion, #470)
  therefore *cannot move this arm by a single rank* — fusion is exercised ONLY in the
  `embeddings` arm. Judge #470 against the embeddings arm's per-question deltas, not this
  one.
* **It is pinned near the metric floor.** `search_keyword` builds its tsquery with
  `websearch_to_tsquery('english', ?)`, which ANDs every non-stop lexeme, so a 10–12 word
  natural-language golden question matches essentially no document. In the committed
  baseline this arm answers a small minority of the prose questions, with most
  per-question MRRs at 0 (the distilled `-kwbag` pairs do better — that is the point of
  the paired section below). A
  floored metric registers *improvements* but almost never *regressions* (a regression
  needs `current < baseline - tolerance`, and you cannot drop below a floor), so its real
  gate signal covers only the handful of questions that clear the floor.

The arm still earns its place: it is the committed, reviewable measurement of the degraded
production path (embedding provider unavailable), and a change that *raises* keyword recall
shows up here. Just don't read it as headroom for a fusion change — that headroom is in
the embeddings arm.

Worth flagging beyond this harness: because `websearch_to_tsquery` ANDs every lexeme, the
production degraded path (`fallback: true`, `search_mode: keyword_only`) returns nothing
for typical multi-word agent questions. Loosening that query is a production-search
ranking change (its own baseline + review, tracked with the fusion work), not part of this
eval harness.

## Synthetic embeddings — read this before trusting an absolute number

CI has no embedding provider, and the test-mode mock returns a per-tenant CONSTANT
vector (so the semantic lane could not discriminate at all). The eval therefore computes
its own deterministic vectors: a **random-projection bag of words** over the document
text and, separately, over the question text (`RetrievalEval.embedding_for_text/1`).

Consequences, stated plainly:

* The semantic lane is a **synthetic stand-in**, not a claim about any provider. It has
  no synonymy — it measures a lexically-grounded topical similarity.
* The query vector is derived from the QUESTION TEXT, never from the labels. A vector
  built out of its own relevant documents would rank them first by construction and pin
  the eval at a vacuous 1.0 that no ranking change could move.
* Read the numbers as a **regression signal**, not an absolute quality score. There is
  **no real-embedding-provider path** on this task: the semantic lane is always the
  synthetic stand-in, in dev, CI, and prod alike (`embedding_opt/2` never calls a
  provider). Do not read a dev/prod invocation as a real-provider measurement — it isn't.

## Adding a labeled question

Append **one line** to `priv/retrieval_eval/golden.jsonl` (it is JSONL — never reformat
it to pretty JSON; line 1 is the header):

```json
{"kind":"question","id":"q-<topic>","question":"<the question as an agent would ask it>","source":"<where it came from>","corpus":[{"doc_id":"d-<topic>-1","title":"...","body":"...","category":"pattern","tags":["..."]}],"relevant":["d-<topic>-1"],"graded":{"d-<topic>-1":3}}
```

Rules the loader ENFORCES (it raises rather than silently scoring fewer questions):

* `id` is unique across the file, and is the row key in the per-question table — renaming
  one discards its baseline history.
* `doc_id`s **and titles** are unique across every question that OWNS a corpus. Every
  corpus is seeded into one tenant, where each other question's documents act as
  distractors. A `corpus_ref` question is exempt because it holds a COPY of its pair's docs
  (see the paired-questions section); the exemption is scoped to those, so two owners
  colliding is still rejected.
* Every `relevant` doc_id exists in that question's own `corpus`.
* `graded` values are integers 0..3 and refer to docs in that corpus. A relevant doc with
  no explicit grade defaults to 1.
* `category` is one of `Loopctl.Knowledge.Categories.all/0`.
* `links` (optional) endpoints are both in that question's own corpus, are never equal, and
  never repeat the same `{from, to, type}` triple; `type` is one of the five `ArticleLink`
  relationship types. See the multi-hop section below for when to add them.

Write questions the way an agent actually asks them, and give each one plausible
distractors — a corpus where only the answer shares any vocabulary with the question
measures nothing.

**Provenance**: `source` is free text and documentation only. Mine candidates from
`article_access_events` (a search followed by a `get`/`context` on the same article is a
confirmed hit), then WRITE the corpus into the fixture. Never label by production article
UUID: CI starts with an empty database, so a UUID label is unscoreable everywhere but the
machine that mined it.

### Known limitation: the committed corpus is synthetic prose

Every committed question today is `hand-authored`, and every corpus document is invented
prose with a few hand-picked distractors — there is no mining tooling in the repo, only
this by-hand instruction. The *self-contained-corpus* design (a portable fixture, no
production DB dependency) is deliberate and worth keeping, but it does **not** require the
TEXT to be invented. A more representative corpus copies REAL article bodies in under
stable `doc_id`s — same portability, but the distractors are the ones fusion (#470) and
recency/authority (#471) actually have to disambiguate, which is exactly where those
changes bite. Until that mining pass lands, read a green embeddings arm as "did not
regress on a synthetic corpus", not "is good on production traffic".

golden_v3 closes the QUERY half of this gap and not the corpus half: the paired `-kwbag`
questions carry query text produced by the real production distiller, but the documents they
are scored against are still the invented prose described above.

## Paired questions: is the injected channel's query shape hurting retrieval? (golden_v3)

71% of this KB's search volume is the injected recall hook, which does not ask questions —
it distils the user's prompt into a stop-word-stripped salience bag of at most 8 terms
(`kb_recall_query`, claude-config `hooks/lib/kb-recall.sh`). Every golden question through
golden_v2 was hand-authored prose, so nothing in this harness could say whether retrieval
survives that transformation.

golden_v3 adds `corpus_ref`, and with it one **paired** question per prose question:
`q-<topic>-kwbag` carries the hook's actual output for that question verbatim and points at
the prose question's corpus, so both are scored against an IDENTICAL corpus with IDENTICAL
labels. The per-question delta is therefore attributable to the query alone.

```json
{"kind":"question","id":"q-rls-new-table-kwbag","question":"enable row level security new tenant scoped table","source":"hook-distilled form of q-rls-new-table ...","corpus_ref":"q-rls-new-table"}
```

Rules the loader enforces: the referring question declares NO corpus/relevant/graded of its
own, the ref resolves to a question in the same file, it is not self-referential, and it is
not itself a ref (one hop — a chain would resolve differently depending on file order).
Refs resolve at LOAD time, so `compute/2`, `corpus/1`, `grade/2` and the report needed no
change, and `corpus/1` still de-duplicates by `doc_id` so a shared corpus is seeded once.

**Do NOT implement a pair by duplicating the corpus under fresh doc_ids.** All corpora seed
into one tenant, so the copy becomes its twin's strongest distractor and the pair measures
the duplication rather than the query.

### The first result: distillation HELPS, in both lanes (measured 2026-08-17)

| metric | prose (26q) | distilled (26q) | delta |
|--------|------------:|----------------:|------:|
| embeddings MRR | 0.7463 | 0.8444 | **+0.0981** |
| embeddings nDCG@5 | 0.7204 | 0.7717 | +0.0513 |
| embeddings recall@5 | 0.7308 | 0.7500 | +0.0192 |
| embeddings answered@5 | 22/26 | 23/26 | +1 |
| keyword_only MRR | 0.1923 | 0.2692 | **+0.0769** |
| keyword_only recall@5 | 0.1538 | 0.2115 | +0.0577 |
| keyword_only answered@5 | 5/26 | 7/26 | +2 |

Six questions improve and **none regresses**: `q-liveview-mount` and `q-audit-chain-sth` go
MRR 0.333 -> 1.000, `q-dispatch-keys` and `q-tenant-id-cast` 0.500 -> 1.000, and in the
keyword arm `q-oban-backoff` and `q-embedding-dimensions` go 0.000 -> 1.000.

**Read the two arms differently, because only one of them transfers.**

* The **keyword_only** result has a mechanical cause that is real in production:
  `search_keyword` builds its tsquery with `websearch_to_tsquery('english', ?)`, which ANDs
  every non-stop lexeme. Dropping five function words from a 13-word question makes a
  conjunctive match far likelier. Shorter genuinely retrieves better on this lane.
* The **embeddings** result is measured against the synthetic random-projection stand-in (see
  the synthetic-embeddings section above), and a bag-of-words projection is structurally
  friendly to a bag-of-words query. Do not read +0.098 MRR as a claim about any real
  provider.

What the pair does NOT settle: production hook queries are distilled from CONVERSATIONAL
PROMPTS, not from well-formed questions, so a real one can be off-topic in a way no pair here
reproduces. The pair rules out "the distillation itself degrades retrieval"; it does not rule
out "the prompt was never about the KB topic".

Three of the distilled forms also exposed defects in the distiller's stop list, which is why
they are worth reading individually rather than only in aggregate: `http`, `not` and `back`
are all stop-listed, so "which **http** client should a new integration use" distils to
"client new integration", and "prove it was **not** rewritten" to "prove rewritten".

## Multi-hop questions: is the graph lane worth its read? (golden_v4)

A question carries an optional `links` list of `{"from": doc_id, "to": doc_id, "type": ...}`
edges (type defaults to `relates_to`), seeded as real `article_links` rows alongside its
corpus. Both endpoints must be in that question's own corpus; a `corpus_ref` pair inherits
its owner's edges along with the corpus, so a pair still differs in the QUERY and nothing
else.

**Why it exists.** #470 shipped the RRF graph-neighbour lane behind a flag and defaulted it
OFF, and it stayed off for months because it could not be judged: the eval seeded no edges at
all, so the lane was a strict no-op here and a lane-on run returned `delta = 0.000`. An
uninformative delta reads as "harmless" and is not a result. Four multi-hop questions
(`q-mh-*`) now put the relevant document on the FAR side of an edge, unreachable from the
query text, so a lane-off run scores them near zero by construction — which is the point.

**Running the experiment.**

```bash
mix loopctl.retrieval.eval --mode both --no-graph-lane --json > off.json
mix loopctl.retrieval.eval --mode both --graph-lane   --json > on.json
mix loopctl.retrieval.eval --mode embeddings --graph-lane --graph-weight 0.10   # sweep
```

Compare the two runs to EACH OTHER, never a lane-on run to the committed baseline — the
baseline is recorded under the shipped default, so that comparison would attribute the
config change to the code change. Three things to know before reading the output:

- **The keyword-only arm cannot move.** The lane lives in the branch where BOTH keyword and
  semantic succeeded, so `--mode keyword_only` is a no-op. In production that also means an
  embedding outage silently disables graph expansion.
- **Read `answered` and `recall`, not MRR alone.** The lane's whole claim is that it makes
  an otherwise-unreachable document reachable; it does not improve the ordering of things
  already found, and it slightly perturbs it. A weight high enough to raise MRR does not
  exist on this curve.
- **Check the single-fact questions for losses, per question.** The aggregate hides the one
  thing that decides the tradeoff. At weight 0.25 the aggregate looked better than at 0.15
  (+1 answered) while `q-liveview-mount` had lost its answer entirely.

The shipped setting (`0.15`) is the largest weight at which no question loses recall or its
answer. The full sweep table lives in `config/config.exs` next to the value, and the
reasoning in `docs/research/kb-retrieval-improvement-plan.md`.

## Tags in the keyword index (golden_v5)

`articles.search_vector` indexes `title` (A), `body` (B) and, since the Phase 3 change,
`loopctl_searchable_tags(tags)` (C). `q-tag-only` is its capability check: the question's
distinguishing term lives ONLY in the answer's tags, so rolling the migration back drops it
to 0.0 in both arms.

Re-measure the motivating number — how much curated tag vocabulary the index cannot see —
against production with:

```sql
WITH sample AS (
  SELECT id, title, body, tags FROM articles
  WHERE status = 'published' AND tags <> '{}' ORDER BY id LIMIT 3000
), t AS (SELECT id, title, body, unnest(tags) AS tag FROM sample)
SELECT (tag ~ '^(url|yt|book|doi|isbn)-') AS provenance,
       count(*) AS tag_instances,
       round(100.0 * count(*) FILTER (
         WHERE NOT (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))
                    @@ plainto_tsquery('english', replace(tag, '-', ' ')))) / count(*), 1
       ) AS pct_invisible
FROM t GROUP BY 1;
```

It read 59.9% invisible for topical tags on 2026-08-17. **Sample, do not scan the whole
table** — the unsampled form times out.

**The golden corpus understates this by construction**: its docs carry ~2 tags each against
production's ~10, so the eval's job here is to prove no regression and to carry the one
capability question, not to size the gain.

## Scoring an LLM stage offline (the rerank fixture)

The eval's provider lane is synthetic by design, so an LLM stage cannot be scored by running
it — CI has no key, a real call costs money, and two runs of the same commit would disagree.
The way round it is record-once / replay-always:

```bash
# once, with a real key, to produce the evidence
ANTHROPIC_API_KEY=... mix loopctl.retrieval.eval --mode embeddings --record-rerank

# thereafter, offline and deterministic
mix loopctl.retrieval.eval --mode embeddings           # reranker off
mix loopctl.retrieval.eval --mode embeddings --rerank  # replays the recording
```

`--record-rerank` runs `Loopctl.Knowledge.Reranker.Llm` for real and writes
`priv/retrieval_eval/rerank_fixture.json`; `--rerank` replays it through
`Reranker.Fixture`. Four things about that file:

- **It is a recording, not an expectation.** A hand-written fixture measures the author's
  taste and reports it as a model's judgement.
- **Keys are the query plus the candidate TITLES in their pre-rerank order.** Ids fold in the
  throwaway tenant id and change every run. Reordering the input is a different question, so
  it must miss rather than replay an ordering chosen for a different starting point.
- **A miss is a no-op, never an error.** Add a golden question and it replays unreranked
  until you re-record — visible in the delta, not as a crash. Re-record after ANY change
  that moves the candidate set, tag indexing and the graph lane weight included.
- **An empty recording is refused.** If every call fails (no key, a 401, a timeout) the task
  raises rather than overwriting real evidence with a provider outage.

Read the result with two cautions. `--mode keyword_only` is unaffected (the reranker sits on
the combined page). And reranking is the measurement most contaminated by the synthetic
vectors: it exists to repair a bad ordering, and the ordering it repairs here was produced by
a random projection, which is bad in ways the real one is not.

**Always read the per-question table, not the aggregate.** Reranking scored +0.105 MRR and
+1 answered while taking `q-mh-rotating-verifier` and its pair from recall@5 1.0 to 0.0 —
the aggregate stayed positive because other questions gained at the same time.

## Re-baselining

```
mix loopctl.retrieval.eval --update-baseline
git add priv/retrieval_eval/baseline_v1.json
```

`--update-baseline` runs BOTH modes and rewrites the baseline as indented, key-sorted
JSON so the diff shows exactly which questions moved. Re-baseline when:

* you added or relabeled golden questions (the baseline records the `golden_version`, and
  the gate also compares the question-id SET, so either kind of change drops the
  AGGREGATE comparison — the aggregates average over different questions, and a rise can
  be composition rather than improvement). It does NOT drop the per-question comparison:
  every question present on both sides is still scored, and one that regressed is named
  and fails the gate. Read those names before you re-baseline — they are exactly what a
  re-baseline is about to absorb. Bear in mind a golden-set change also moves the shared
  corpus (every question's documents are seeded into one tenant, so a new question adds
  distractors to every other) and can relabel, so confirm the cause of a drop rather than
  assuming the ranking caused it, or
* a ranking change is an intentional, reviewed IMPROVEMENT — commit the new numbers
  together with the change so the delta is visible in the PR.

Never re-baseline to make a red gate green. The whole point is that the numbers move only
through a reviewed commit.

**Re-baseline on the SAME Postgres major the gate runs on (CI = `pgvector/pgvector:pg16`).**
The `:keyword_only` arm's `answered` set is decided by Postgres `english` full-text stemming
and `ts_rank_cd`, which are stable WITHIN a PG major but can shift ACROSS one. Dev machines
span pg16/pg14; a baseline captured on pg14 can then read as a spurious regression against
CI's pg16 (or mask a real one). Ranking ties inside a run are already made deterministic
(article-id secondary sort in both the merge and the keyword `ORDER BY`, plus deterministic
seeded article ids), so this is the remaining cross-environment variable — pin it by
re-baselining on pg16.

### #471 re-baseline: the priors are a like-for-like improvement (no accepted regression)

The #471 ranking priors (recency + category authority — the source_type/provenance half was
removed on 2026-08-21 by owner decision) ship **default-on in every
env** (`config/config.exs`: `knowledge_recency_weight` 0.3, `knowledge_authority_prior_enabled`
true, `knowledge_authority_strength` 0.05 — no `test.exs` override). golden_v2 also adds one
new question (`q-recency-fusion`) that exercises the recency prior directly.

**Read the priors' effect on a LIKE-FOR-LIKE corpus — same golden_v2 question set, priors
toggled OFF vs ON — not by diffing the golden_v1 (25q) baseline against the golden_v2 (26q)
one.** That cross-corpus diff conflates two changes (a bigger distractor pool AND the priors)
and produces a misleading "regression". Measured on golden_v2 with the priors OFF vs ON
(reproduce with `RankingPriors` disabled via the `recency_weight: 0.0` /
`authority_prior: false` search opts):

| Metric (embeddings arm) | priors OFF | priors ON | delta |
|-------------------------|-----------:|----------:|------:|
| MRR                     | 0.7206     | 0.7463    | +0.0257 |
| nDCG@10                 | 0.7328     | 0.7499    | +0.0172 |
| nDCG@5                  | 0.6999     | 0.7204    | +0.0205 |
| recall@10               | 0.8077     | 0.8077    | flat |

Every aggregate metric is **flat or up** with the priors on, and NO pre-existing question
regresses. Two pre-existing questions improve: `q-heavy-read` nDCG@10 **0.5112 -> 0.9449**
(+0.434) and `q-keyword-fallback` nDCG@10 **0.8396 -> 0.8520** (+0.012). So AC-6's
"aggregate >= baseline" holds on the merits.

What is actually true about the numbers, stated plainly:

* **The lift is RECENCY, not authority.** On this corpus "recency-only" (authority OFF)
  scores identically to "both on" — the authority prior contributes **zero** net movement.
  This synthetic corpus has few authority-decidable near-ties (the deterministic seeded-id
  secondary sort already resolves most RRF ties), so the authority prior's merit is NOT
  demonstrated by this eval; only recency's is. That is a limitation of the synthetic
  corpus (see the "committed corpus is synthetic prose" note above), not evidence the
  authority prior is inert in production.
* **The keyword_only arm is unchanged by the priors** on golden_v2 (MRR/nDCG@10/recall@10
  identical OFF vs ON): its five answered questions have same-age docs (recency inert) and
  their order is fixed by the id tie-break. Recency needs no embedding, so it *can* apply
  here — it simply has nothing aged to move.
* **The earlier "0.86034 -> 0.85196 accepted regression" was a cross-corpus artifact, not a
  priors effect.** 0.86034 was `q-keyword-fallback` on the SMALLER golden_v1 (25q). golden_v2
  added `q-recency-fusion`, whose four corpus docs become distractors in the single shared
  seeding tenant; those distractors alone dropped `q-keyword-fallback` to 0.8396 BEFORE any
  prior ran. The recency prior then demotes those (deliberately stale, `age_days` 60–500)
  distractors and lifts the grade-2 answer from rank 10 back to rank 8, recovering to 0.8520.
  The priors *counteract* the corpus-expansion dip; they do not cause one.

The gate compares against the regenerated-and-committed golden_v2 baseline (the normal
re-baseline workflow below), and `q-keyword-fallback` is committed at its priors-on 0.8520 —
so the gate is internally consistent and there is nothing to "accept".

#### Operational caveat: "recency" is last-mutation time, not authored time

The recency prior measures a document's age from `updated_at` (via
`RankingPriors.recency_decay/2`), and `updated_at` is bumped by ANY row write that changes
content — including a re-embed / content-hash refresh (`Knowledge.update_embedding/4`). A
model migration or a **bulk re-embedding backfill therefore resets every touched note's
apparent freshness to "now" and, run corpus-wide, globally flattens the recency signal**
until authored-age drift re-accumulates. This is inherited from `knowledge_context` (#471's
AC mandates reusing that exact field + decay), but #471 surfaces it on the PRIMARY search
path — so after any mass re-embed, expect search ordering to shift, and prefer re-baselining
the eval only once the corpus timestamps have settled. There is no separate authored/source
timestamp to fall back to.

## The CI gate

The `retrieval-eval` job in `.github/workflows/ci.yml` runs
`mix loopctl.retrieval.eval --mode both --fail-on-regression` against a fresh
`pgvector/pgvector:pg16` service and gates `deploy`.

Failure modes, all of which exit non-zero:

* an aggregate metric is below baseline by more than the tolerance (default 0.005;
  `answered` has no tolerance — any lost question fails),
* a metric became undefined,
* a question shared with the baseline regressed, or carried a metric the baseline has no
  value for — **both gate on EVERY status**, including a run whose aggregates are fine and
  a run whose aggregates could not be compared at all,
* the golden set version does not match the baseline's, or its question-id set does not
  (in both cases the aggregates are dropped but the shared questions are still scored, so
  the run can fail on a NAMED question rather than only on "cannot compare"),
* the baseline file is missing or unreadable **in gate mode** (a gate that passes because
  it had nothing to compare against is a false green),
* the golden set has no questions.

When the gate fails, read the per-question table in the job log: the `d.mrr` column names
the winners and losers, so a fusion change that helps ten questions and destroys three is
visible rather than averaged away. The per-question verdict is not merely diagnostic — it
GATES, on every status.

**How an intentional net-improving tradeoff ships.** Land the ranking change ALONE first,
so the gate scores it against the standing baseline and names every question that got
worse; decide, in the PR, that the trade is worth it. Then re-baseline in its own reviewed
commit. Never inside the ranking change: a baseline regenerated by the commit it is meant
to judge compares the new code against its own output. That is not hypothetical — scoring
pre-#693 code against `golden_v5` on 2026-08-25 found three questions whose correct answer
had been pushed down the ranking across the `v3 -> v4 -> v5` growth (`q-self-report` 1.00
to 0.33 MRR, `q-egress-policy` 1.00 to 0.50, `q-audit-chain-sth` 0.33 to 0.25). Recall was
intact on all three, so nothing was lost, only demoted, and the aggregate rose the whole
time. All three questions were present in every one of those baselines.
