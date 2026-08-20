# Runbook — monthly `search_events` review

`search_events` records one row per SEARCH ATTEMPT, including the ones that returned
nothing, degraded to keyword-only, or were rejected before they ran (#658). It exists
because the two failure modes that matter most were invisible in `article_access_events`,
which only records surfaced results.

A capture surface nobody reads is a capture surface that gets deleted. This is the
procedure, monthly, ~15 minutes.

## 0. Enrich first, on the machine that did the searching

Three columns cannot be filled by the client and are wrong or null until this runs:

- `client_model` — no model variable exists in the MCP server's environment.
- `client_effort` — likewise absent from that process (`CLAUDE_EFFORT` is set for Bash-tool
  invocations, not for the MCP server), so the column is NULL until enriched.
- `client_kind` — the client reports the SESSION's kind, not the caller's. One MCP process
  serves a session and every agent it dispatches, so it labels every search `main`. **An
  un-enriched `client_kind` is not caller-level truth** — do not compute a per-kind rate
  from one.

The task writes through `AdminRepo`, so point `DATABASE_URL` at prod first — same recipe as
step 1 below, via the `fly-mpg-connect` skill:

```bash
flyctl proxy 15432:5432 -a ecf-postgres &          # loopctl's database is named `loopctl`
export DATABASE_URL=postgres://<user>:<pass>@localhost:15432/loopctl

# on each dev machine that runs agents (transcripts never leave the machine)
mix loopctl.enrich_search_events --dry-run          # see what would change
mix loopctl.enrich_search_events --since-days 45    # then write
```

Run it on EVERY machine that runs agents, not just one. The task only answers rows whose
`client_host` is the machine you are on (see below), so another machine's rows stay null
until you run it there.

It joins on `(client_session_id, query)`, because a subagent's transcript records its
PARENT's session id — see `Loopctl.Knowledge.SearchEventEnrichment` for why the pair is
the only unambiguous key, and why a key two transcripts disagree about is dropped rather
than guessed.

The task is **machine-scoped, and now enforces it**: the query-only fallback below is
applied only to rows whose `client_host` is the machine you are running on. Another
machine's rows stay null until you run it there, which is the correct outcome — two machines
searching the same wording is ordinary, and their transcript trees never see each other.

A **resumed** session breaks that key: the restarted MCP server reports a fresh session id
while the transcript keeps appending under the original, so the pair can never match. The
task falls back to the query alone for those rows, and only for a query that is unambiguous
across the whole transcript tree (measured: 96% of distinct queries are). `client_model` and
`client_effort` are filled, never overwritten; `client_kind` IS corrected, because the value
the client sent is a session-level assertion rather than an observation. Re-running is safe
and idempotent either way.

## 1. Run the canonical queries

They live in the `Loopctl.Knowledge.SearchEvent` moduledoc, beside the schema they read,
and are deliberately NOT duplicated here — one copy cannot go stale against the other.
Open that file and run them against prod (`docs/runbooks/` has the connection recipe under
the fly-mpg notes, or use the `fly-mpg-connect` skill).

Add this one once the enrichment above has run — it is the whole point of the split:

```sql
-- Failure rate by agent kind and model. The baseline measured from transcripts was
-- main 8.2% / workflow 6.0% / subagent 3.7%; `child` averages that spread away.
SELECT client_kind, client_model, count(*),
       round(100.0 * count(*) FILTER (WHERE outcome IN ('zero_results','rejected'))
             / count(*), 1) AS bad_pct
  FROM search_events
 WHERE tenant_id = $1 AND inserted_at > now() - interval '30 days'
 GROUP BY 1, 2 ORDER BY 3 DESC;
```

## 2. Segment by origin BEFORE concluding anything

Server-side search traffic is roughly 4x transcript traffic and is dominated by
automation — one measured month carried `elixir` x2,056 as a query, 722
notification-derived hook queries, and 512 harvest dedup probes. A utilization metric
computed over that mix measures automation, not agents.

Split on `tool`, `client_entrypoint` and `client_kind` first. If a number moved, establish
which segment moved before attributing it to anything.

**The single most important filter is `client_host IS NOT NULL`.** A row without it never
passed through the MCP client at all, so it cannot be an agent's search: the UserPromptSubmit
recall hook and `scripts/smoke.sh` call the API directly. In the first 11 hours after this
table went live, 131 of 133 rows were exactly that — repeated `elixir` probes from the smoke
check and keyword-stripped `memory_recall` calls from the recall hook. Any rate computed over
the unfiltered table measures this project's own automation.

One operational trap belongs here too: **a long-running session keeps the mcp-server build it
booted with.** `npx` updating the cache does not restart it, so after publishing a version
that changes what the client sends, sessions started before the publish keep sending the old
payload until they are restarted. If context columns are unexpectedly sparse, check
`client_version` before suspecting the server.

## 3. What to look at, in order

| Signal | Healthy as last measured | What a regression means |
|---|---|---|
| zero-result rate on the default `combined` path | 0.7–0.9% | corpus gap, or a query-shape change — check the query-shape query before blaming the corpus |
| `degraded` rows by `fallback_reason` | near zero | an embedding provider problem, NOT a retrieval one. `no_embedding_key` means a tenant never provisioned one |
| `rejected` rows by `rejection_reason` | near zero | a client is sending something the API refuses — that is a tool-surface defect, and historically the largest single class |
| search→open follow-through | 1–7%, flat | the biggest number in this area and the least moved by anything shipped so far. See #652's closing section |

## 3a. Judging a RANKING change — two objectives, and a position correction

Two rules, both from the IR literature this corpus already carries (Bing Liu, *Web Data
Mining* 2nd ed.; search the wiki for the `bing-liu` tag). Neither is optional, and both exist
because a single-proxy loop optimises the wrong thing.

**Never judge a ranking change on follow-through alone.** Engagement and relevance are
distinct objectives — the sponsored-search finding is that a high-CTR/low-relevance result
earns revenue while destroying trust, and "revenue optimisation alone is insufficient". Our
analogue: a ranking can lift opens by returning fewer, safer, more clickable results and be
worse for the agent. So judge on BOTH:

1. observed opens, position-corrected (below), and
2. `mix loopctl.retrieval.eval` — the golden-question relevance gate.

**A variant that lifts opens while regressing the eval loses.** And remember the other half:
a missing open is not disinterest. An agent whose question is answered by the snippet
correctly opens nothing, and that is a success this metric scores as a failure. Follow-through
is a floor, never a satisfaction rate.

**Correct for position before comparing two arms.** `mode_used` now distinguishes
`combined_curated` from `combined_retrieved`, and the curated arm puts its winner at rank 1
BY CONSTRUCTION. Clicks carry position bias, so rank 1 is opened more whatever sits there —
a higher raw follow-through on the curated arm is therefore not evidence the hoist helped.
Compare the arms at the SAME rank, using the position-corrected query in the
`Loopctl.Knowledge.SearchEvent` moduledoc.

One caution specific to our volume: the arms are thin, and automation rows surface results and
never open anything, which depresses every rank uniformly. Segment on `client_host IS NOT NULL`
here too, and do not read a few dozen rows as a result.

## 3b. The follow-through number has a channel-shaped hole — and now a second reading

`search_follow_through` and `followed_through` correlate a search with an open on
`api_key_id`. The injected recall hook searches under a DIFFERENT key from the session that
reads: measured 2026-08-17, the hook's key made 1,071 searches and **1** deliberate read
ever, the MCP/session key 0 such searches and 2,535 reads. **So the channel carrying 71% of
search volume has always scored a structural zero in those fields, and that zero means
unmeasurable, not unread.**

Reads now carry `origin_search_id` / `origin_attribution`, resolved server-side at write
time, and the metrics payload reports:

| field | unit | read it as |
|---|---|---|
| `attributed_opens` | READS | opens whose originating search is known |
| `cross_key_opens` | READS | **the injected channel** — surfaced by one key, read by another |
| `direct_opens` | READS | agent went straight to the article (link, cited id) — not a miss |
| `searches_scored` | SEARCH CALLS | the base the three below partition — **not** `searches` |
| `searches_scored_with_follow_through` | SEARCH CALLS | of those, the ones that opened something |
| `searches_reformulated` | SEARCH CALLS | same SESSION asked a DIFFERENT question, in-window, nothing opened — a real failure |
| `searches_quiet` | SEARCH CALLS | neither opened nor re-asked — **still ambiguous** |

Two things to hold onto when reading them:

- **Units differ from `followed_through`.** That counts SURFACED RESULTS later opened; the
  `*_opens` fields count READS. They are not comparable and neither supersedes the other.
- **`searches - searches_scored` is `n/a`, not zero.** A search is scoreable for
  reformulation only if it carries a session identity (stamped forward-looking, so every row
  written before it shipped is unscoreable) and comes from a channel that can react to a
  result — the recall hook and the session-start auto-query cannot, because each emits one
  mechanically-distilled query per prompt and never sees what came back. Both remain in every
  other denominator, precision included; only this one metric cannot see them. Scoring on
  `api_key_id` instead is step 2's shared-key trap re-entered one metric later: two keys
  search this system, the median gap between consecutive searches on one is 127 seconds, and
  the figure that produced was 97% where the session-scoped one is 27%.
- **`quiet` is not "sufficed".** Splitting `reformulated` out removes the one unambiguous
  failure from the not-opened bucket; it does NOT resolve the snippet-sufficed-vs-ignored
  ambiguity in step 4 below. Nothing here turns a floor into a satisfaction rate.

Cross-key attribution is circumstantial by construction — two agents in one tenant can reach
one article independently — which is why it is a separate labelled field rather than folded
into `attributed_opens`.

## 3c. Segmenting opens by entrypoint — and the join key that is not the primary key

`origin_search_id` is what finally lets an open be attributed to the CHANNEL that surfaced
it, because `client_entrypoint` lives on `search_events` and nothing on the read row carries
it. The join is:

```sql
JOIN search_events se ON se.search_id = a.origin_search_id
```

**`search_events.search_id`, never `search_events.id`.** They are different columns: `id` is
the row's primary key, `search_id` is the per-call correlation id the search site mints once
and threads to BOTH the `search_events` row and every surfaced `article_access_events` row.
Joining on `id` returns zero matches for every entrypoint, which reads exactly like "nothing
follows through" — the failure that produced the withdrawn table in the retrieval plan's
§3.1, made again on 2026-08-17 by the person who had just written that section. Sanity-check
any such query with

```sql
SELECT count(*) FROM article_access_events a
WHERE a.origin_search_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM search_events se WHERE se.search_id = a.origin_search_id);
```

which must be 0. A non-zero count means retention has already pruned `search_events` (it is
the shorter-lived table), not that attribution is broken — bound the window and re-run.

### First traffic (v523, 2026-08-17 18:00-21:00 UTC)

| entrypoint | tool | searches | searches opened | attribution of the opens |
|---|---|---:|---:|---|
| `hook` | `memory_recall` | 31 | 2 | 3 reads, ALL `cross_key` |
| `cli` | `knowledge_search` | 6 | 3 | 3 reads, `same_key` |
| `cli` | `knowledge_hybrid_search` | 6 | 2 | 2 reads, `same_key` |
| `smoke` | `knowledge_search` | 14 | 0 | - |
| `session-start` | `memory_recall` | 10 | 0 | - |

Three hours is not a rate and must not be quoted as one. What it does establish is
MECHANISM: every hook open is `cross_key` and every cli open is `same_key`, which is the
predicted split, and it confirms the old same-key metric could not have counted a single one
of the hook's.

**Correction (2026-08-17):** an earlier version of this paragraph said `session-start`
"belongs with `smoke` in the filter-me-out class". **It does not, and it is not excluded.**
It is one auto-query per session from `hooks/session-start.sh`, issued by a real session that
goes on to do real work — a channel to be measured, not infrastructure. It began declaring
itself in claude-config#322; before that it sent no client context and sat in the NULL
bucket, so expect a step change out of NULL dated 2026-08-17 that is bookkeeping rather than
behaviour.

What IS excluded alongside `smoke` is `skill-eval` (`@infra_entrypoints`):
`bin/skill-trigger-eval.py` runs each eval query through a real `claude -p` subject whose
recall hooks search for real, and **the subject is killed at its first tool call** — those
searches can never follow through while landing in every denominator. Two of its queries were
identifiable as distinct strings appearing exactly 12 times (4 runs x 3 repeats).

The retrieval plan blamed the recall CANARY for this contamination and was wrong: the canary
pins every hook invocation to `http://127.0.0.1:9` behind a recording curl shim and issues no
request to loopctl at all.

## 4. The trap

Search returns; agents do not open. Search-to-read has sat near 27:1, and 1.74% of
published articles have ever been opened. That is a harness/consumption problem, not a
search or corpus one — fixing retrieval further will not move it. Do not spend a month's
work on the retrieval side on the strength of a utilization number that was never
segmented by origin (step 2).

## Appendix — regenerating the retrieval baseline

Adding a golden question (for example, one grown from real logged queries) makes the eval
run `:incomparable`: `question_set_changed?/1` compares the question-id SET and refuses,
rather than letting an unmatched question read as a non-regression. So the baseline has to be
regenerated whenever the question set changes.

**Either CI or a local run is fine — what must match is the Postgres MAJOR.** The eval's
vectors are deterministic functions of the committed text, so no embedding provider is
involved, and the corpus cannot vary either: the task mints a THROWAWAY TENANT and
`search_combined/3` is tenant-scoped, so a developer's accumulated dev rows are invisible to
it. The one real cross-environment variable is Postgres `english` FTS stemming and
`ts_rank_cd`, which are stable within a PG major and can shift across one — so re-baseline on
pg16, matching CI's `pgvector/pgvector:pg16`. See `retrieval_eval.md`.

**This paragraph previously said the opposite** — "do it in CI, not locally", because "CI
scored `mrr 0.746 / answered 22 of 26`; a local run of the same command scored
`0.192 / 5 of 26`". Those two figures are not CI vs local: they are the **embeddings** and
**keyword_only ARMS** of the same `--mode both` run on golden_v2, which scores exactly
0.7463/22 and 0.1923/5. Disproved directly on 2026-08-17: a golden_v3 baseline regenerated
LOCALLY on pg16 was reproduced by CI to three decimals on both arms (`delta=+0.000` for
mrr, ndcg@5, ndcg@10 and answered@5). Recorded rather than deleted because the claim cost a
CI round-trip per re-baseline and would have been re-derived from the same misreading.

The CI path remains available and is the better choice when you do not have a pg16 to hand:

```bash
gh workflow run CI --ref <your-branch> -f regenerate_retrieval_baseline=true
gh run download <run-id> -n retrieval-baseline      # then commit it deliberately
```

The gate step is skipped on a regeneration run — comparing a run against a baseline it just
wrote would pass whatever the numbers are. CI never commits the file: a gate that can rewrite
its own threshold unattended is not a gate.
