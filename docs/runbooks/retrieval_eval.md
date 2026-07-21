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
```

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

The keyword-only arm scores far lower than the embeddings arm. That is the point: it is
the arm with headroom, so a fusion change (e.g. reciprocal rank fusion) has somewhere to
show a gain, while the embeddings arm is the arm with the least slack for a regression to
hide in.

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
* Read the numbers as a **regression signal**, not an absolute quality score. A run
  against a real provider is the same mix task invoked in dev/prod.

## Adding a labeled question

Append **one line** to `priv/retrieval_eval/golden.jsonl` (it is JSONL — never reformat
it to pretty JSON; line 1 is the header):

```json
{"kind":"question","id":"q-<topic>","question":"<the question as an agent would ask it>","source":"<where it came from>","corpus":[{"doc_id":"d-<topic>-1","title":"...","body":"...","category":"pattern","tags":["..."]}],"relevant":["d-<topic>-1"],"graded":{"d-<topic>-1":3}}
```

Rules the loader ENFORCES (it raises rather than silently scoring fewer questions):

* `id` is unique across the file, and is the row key in the per-question table — renaming
  one discards its baseline history.
* `doc_id`s **and titles** are unique across the WHOLE file. Every question's corpus is
  seeded into one tenant, where each other question's documents act as distractors.
* Every `relevant` doc_id exists in that question's own `corpus`.
* `graded` values are integers 0..3 and refer to docs in that corpus. A relevant doc with
  no explicit grade defaults to 1.
* `category` is one of `Loopctl.Knowledge.Categories.all/0`.

Write questions the way an agent actually asks them, and give each one plausible
distractors — a corpus where only the answer shares any vocabulary with the question
measures nothing.

**Provenance**: `source` is free text and documentation only. Mine candidates from
`article_access_events` (a search followed by a `get`/`context` on the same article is a
confirmed hit), then WRITE the corpus into the fixture. Never label by production article
UUID: CI starts with an empty database, so a UUID label is unscoreable everywhere but the
machine that mined it.

## Re-baselining

```
mix loopctl.retrieval.eval --update-baseline
git add priv/retrieval_eval/baseline_v1.json
```

`--update-baseline` runs BOTH modes and rewrites the baseline as indented, key-sorted
JSON so the diff shows exactly which questions moved. Re-baseline when:

* you added or relabeled golden questions (the baseline records the `golden_version`; a
  mismatch makes the gate refuse to compare rather than report meaningless deltas), or
* a ranking change is an intentional, reviewed IMPROVEMENT — commit the new numbers
  together with the change so the delta is visible in the PR.

Never re-baseline to make a red gate green. The whole point is that the numbers move only
through a reviewed commit.

## The CI gate

The `retrieval-eval` job in `.github/workflows/ci.yml` runs
`mix loopctl.retrieval.eval --mode both --fail-on-regression` against a fresh
`pgvector/pgvector:pg16` service and gates `deploy`.

Failure modes, all of which exit non-zero:

* an aggregate metric is below baseline by more than the tolerance (default 0.005;
  `answered` has no tolerance — any lost question fails),
* a metric became undefined,
* the golden set version does not match the baseline's,
* the baseline file is missing or unreadable **in gate mode** (a gate that passes because
  it had nothing to compare against is a false green),
* the golden set has no questions.

When the gate fails, read the per-question table in the job log: the `d.mrr` column names
the winners and losers, so a fusion change that helps ten questions and destroys three is
visible rather than averaged away.
