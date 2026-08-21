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
   (`propose_article/3` at `knowledge.ex:462`; the four `gate_proposal/4` clauses at `:472-522`).
   **SIX outcomes, not four** — `:duplicate`, `:low_novelty`, `:unknown`, `:novel`,
   `:deduplicated` (`created: false`, returned when `create_article` hits the idempotency-key path,
   `knowledge.ex:573-575`), and `:skipped_low_novelty` (`created: false`, `article` may be `nil`).
   A caller matching only the first four falls through on either of the last two, both reachable.
   `:duplicate` returns the canonical neighbor without creating; `:low_novelty`
   is created but **forced to `status: "draft"`** (`:494`) with novelty stamped into
   `metadata.proposal_novelty` (`stamp_proposal_metadata/2`, `:694-707`) so a smarter consumer decides
   — UNLESS the caller passes `on_low_novelty: :skip` (for an UNATTENDED writer whose drafts nothing
   would review), which creates NOTHING and returns `:skipped_low_novelty` with the near-neighbor
   (`skip_low_novelty/4`, `:540-562`). That skip is decided LAST: an invalid `project_id`, an
   `idempotency_key` match, and an exact active-title collision are all still answered normally
   rather than dropped.
   Two branches that are easy to miss: `:duplicate` **falls through to create** if the canonical
   neighbor vanished between assess and now (`:474-482`), and `:unknown` creates only BY DEFAULT — a
   caller passing `on_gate_unavailable: :skip` gets `{:error, :gate_unavailable}` and nothing is
   created (`:509-515`). The assessor is config-injected (`Loopctl.Knowledge.ProposalGate`, `:463-466`)
   — do not hardcode it.
2. **Hybrid search provenance** — `Loopctl.Knowledge.hybrid_search/3` (in `knowledge.ex`).
   `:curated` wins ONLY when a governed curated source's **absolute** (never pool-relative) confidence
   (`absolute_score/1`) clears a scale-matched threshold AND beats the best retrieved
   candidate by a margin (`hybrid_curated_threshold_and_margin/1`; the pure decision is
   `resolve_provenance/4`) AND is authoritative (not superseded/conflicted — the caller
   passes only `list_curated_sources/2`-filtered scores). Otherwise `:retrieved`. Both branches return identical `results`/`meta`
   key sets — callers branch on `meta.provenance` alone. A sparse pool must never let a near-but-wrong
   curated doc win.
3. **All heavy KB reads route through `Loopctl.HeavyRead`** — semantic search, novelty, suggest-links,
   distant-pairs, enumeration (`knowledge.ex:12`). See the `tenancy-rls` skill for the pool/pgbouncer
   reasoning; never run these on `Repo`/`AdminRepo`.
4. **KB-content curation is agent-role because it is NON-DESTRUCTIVE + audited (#331)** —
   `knowledge_create`, `knowledge_update` (ID-preserving in-place edit),
   `knowledge_archive`/`knowledge_delete` (soft delete → `status: :archived`, row retained), and
   `knowledge_resolve_conflict` in all dispositions. **Non-destructive is not the same as reversible,
   and archive is the case that separates them (#605/#606):** `:archived` is TERMINAL — `Article`'s
   `@valid_transitions` has no `{:archived, _}` and there is no unarchive function, so the only way
   back is a `user+` PATCH with an explicit status. Nothing is destroyed and everything is audited,
   which is what earns agent role; nothing automated restores it, which is why an unattended writer
   must reach for `unpublish` (`{:published, :draft}`, undone by `publish`) instead. The `:user` set
   is single-article `unpublish` plus ALL the SET-BASED bulk ops — `bulk_publish`, `bulk_unpublish`
   and the ENTIRE `bulk_delete` action, soft path included (`article_workflow_controller.ex:37-39`).
   **Both criteria matter**: set-based blast radius (one call mutates an unbounded set) AND
   irreversibility (`bulk_delete` carries a hard-delete path) — see the controller `@moduledoc`
   (`:9-18`). Single-article ops are agent-role precisely BECAUSE nothing they do destroys a row, so
   never drop that property when reasoning about a new op.
   `drafts`/`publish` are `:orchestrator` (`:33`).
   Agent edits are visibility-scoped: an agent can only touch an article it can see. (See `chain-of-custody`.)
   **Recording a verdict is agent-role; AUTHORIZING the unattended RETIREMENT is not.** The
   conflict PAIR is manufacturable — the queue is fed by a mechanical similarity threshold — so
   `annotate_conflict/3` GRANTS a `:supersede`'s `confidence` from the recorder's role
   (`grant_confidence/3`, `:actor_role` resolved server-side from the key) instead of accepting
   it from params: an agent asking for `:high` is recorded at `:medium` with the ask kept in
   `requested_confidence`, and a `:high` supersede must carry `evidence`. `:merge` is NEVER
   capped — it synthesizes a new DRAFT and retires nothing, so capping it disabled the
   disposition and bought no safety. Scope any new gate to what it actually protects.
   A verdict nothing will act on does NOT settle the pair: `conflict_unresolved_subquery/0`
   settles on `executable_resolution/0`, so a capped or unattributed row leaves its pair in
   `GET /knowledge/conflicts` to be re-recorded.
   **A pair the system never flagged is REACHABLE but not self-judgeable (#730).**
   `Knowledge.assert_conflict/3` (`POST /api/v1/knowledge/conflicts`, agent+) creates the
   `:potential_conflict` link a caller cannot create directly, stamped
   `auto_generated: false, asserted: true` and carrying a REQUIRED `evidence` — the case it
   exists for is a session that just wrote a correction, whose pair is minutes old and may
   never be similar enough to be auto-flagged. Three properties keep the kb-02 guard intact,
   and each has a mutation-verified test: an assertion **never reaches curated suppression**
   (`open_conflict_subquery/1` and `article_in_open_conflict?/2` still require
   `auto_generated`, or an agent could retract any article from the governed answer path by
   disputing it); the **asserter may not record the verdict**
   (`validate_not_self_asserted/2` → `409 self_asserted_conflict`, fail-closed on an unknown
   recorder, and refusing an ANCESTOR/DESCENDANT dispatch of the asserting one — siblings are
   separation, exactly as the L4 gates read lineage; re-checked in `apply_flagged_resolution/3`
   on the PRINCIPALS stamped at assert and verdict time, with the audit label evaluated IN
   ADDITION, never as an else-branch, since only the LAST verdict's principal is on the row);
   and an assertion **never overwrites a system flag** — `fetch_conflict_flag/3`
   prefers `auto_generated` on a tie. Pre-settling is closed on BOTH sides: the self-refusal
   covers every disposition, and `conflict_unresolved_subquery/0` — the QUEUE only — settles a
   flag with a verdict that POSTDATES it, so two principals cannot dismiss a pair against a
   genuine system flag raised over it later. Curated suppression deliberately keeps the
   older predicate-free `judged_pair_subquery/0`: the automatic drain skips any pair that
   already carries a verdict row, so a re-flagged judged pair counted as unjudged would
   withhold both articles with nothing able to release them. Ids are cast (`cast_distinct_pair/2`) before any query interpolates them,
   and visibility is checked BEFORE existence so an invisible id and a nonexistent one are
   one answer. Hiding a pair behind a row that will never apply is the black hole to avoid.
   **Corroboration covers BOTH duplicate signals** (`Consolidation.corroborated?/3`), and the
   winner is the OLDEST member, not the longest. An `idempotency_key` AND a normalized title
   are both caller-controlled, so corroborating content the same party wrote proves nothing —
   age is the one input a later writer cannot manufacture. Scoring is keyed by
   `{drift_signal, member_id}` — a group scored under the other signal's normalized key finds
   nothing and withholds (fail-closed).
5. **Heat must not rank on a signal heat produces** — `Knowledge.heat_index/2`
   (`knowledge.ex:10884`; the counted set is `@heat_read_access_types`, `:10754`). The heat index is the one retrieval route that
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

6. **The `idem-` tag namespace is reserved, enforced at write time, and is NOT an idempotency
   mechanism** — `Loopctl.Knowledge.IdempotencyTag`, enforced from the one place both changesets
   converge (`validate_tag_format/2` in `article.ex`), so it binds every writer (API controllers,
   `ContentIngestionWorker`, `ReviewKnowledgeWorker`, OKF import) rather than one call site — the
   same reasoning as `Coordination`'s reserved `claim:` key prefix. A tag claiming the prefix must
   be `idem-<family>-<digest>` with a **12- or 40-char** lowercase hex digest: both eras, because
   the sourcers' suffix was truncated from a full sha1 to 12 and a rule that knew only the current
   form is the drift bug that made pre-truncation captures invisible. Malformed → 422 naming the
   remedy; **never** a silent re-prefix (rewriting a caller's tags makes the response body a lie).
   The 422 is what a CALLER sees on `POST`/`PATCH /api/v1/articles`. Every MACHINE path drops
   the tag instead, because a whole batch must not die on one string a model or a foreign
   document produced: OKF `sanitize_tags/1` drops a tag that sanitizing COERCED into the
   namespace (discriminating on whether the string CHANGED — a well-formed reserved tag arriving
   byte-identical is the article's own capture identity and MUST survive, or a native bundle's
   round trip and the merge path silently delete it); `ReviewKnowledgeWorker` and
   `ContentIngestionWorker` strip a malformed reserved tag from extractor output pre-insert
   (a review's articles share one `Multi` whose `:insert_failed` changeset discards the job
   permanently, and an ingested article whose changeset is invalid is dropped WHOLE — body and
   all — before `insert_all`); and `Memory.sanitize_graduation_tags/1` filters one out, since a
   failed graduation insert still STAMPS the memory graduated and burns its one shot.
   **Any new tag rule on the Article changeset must be mirrored in those four**, and in
   `KnowledgeMocWorker`'s `@excluded_prefixes`, which suppresses `idem-` so a capture id can
   never become a published `Index:` hub (its match is by PREFIX: `url-` does NOT cover
   `idem-url-…`).
   The reservation is FORWARD-looking: pre-reservation tags carry the bare `<family>-<digest>` form
   with no prefix to match on, so reads need the independent shape discriminator `legacy?/1`, and
   the bare form is still WRITABLE until the client half (mkreyman/claude-config#222) adopts the
   reserved form. `legacy?/1` requires BOTH a known source family and a hex digest — a bare
   `<anything>-<hex>` also describes `commit-<sha>` and `release-202604150930`, and promoting one
   of those fabricates a capture identity that `--drop-legacy` then makes irreversible.
   `mix loopctl.reserve_idempotency_tags` promotes the corpus (dry-run default;
   `--drop-legacy` is the second pass, only after clients switch).
   **What this is not:** a tag is caller-controlled data, so reserving its namespace is defense in
   depth, not authority. The server-guaranteed key is the `articles.idempotency_key` column with
   its per-tenant unique index — prefer it, and do not treat a tag as proof of capture identity.

## Ranking must never key on HOW a document got in (owner decision, 2026-08-21)

`Loopctl.Knowledge.RankingPriors` carried two PROVENANCE priors — a `source_type` table
("human/reviewed provenance over raw automated ingests") and a first-party/third-party split
keyed on the sourcers' capture tags (`book-`/`url-`/`yt-`/`doc-` and the bare kind tags).
**Both are removed.** Mark's reasoning, which outlives the measurement: *"if we heavily favor
the internally produced knowledge, we would never learn anything new and unexpectedly
useful... agents improve and I don't want less intelligent agents to decide what to pick for
more intelligent future agents. I want the decision of what knowledge to use and how to
combine it to be done on the receiving side."*

The prior's own evidence did not survive checking. It cited a 26.7x reads-per-article gap —
a statistic whose denominator is the harvest's own volume (~96% of the corpus), so it falls
~1/N mechanically. The measure that actually answers "is this material worse?" is
**surfaced-to-opened conversion**, and rank-stratified on the live corpus it converged by
rank 3 and INVERTED by rank 4 (first-party 1.95% vs third-party 1.96% at rank 4; 1.57% vs
1.74% at rank 5). Its discriminator-verification claim (98.5%/0.4%) had also gone stale.

**What is still allowed**, so this is a rule and not a mood: relevance itself (RRF — that IS
the retrieval); DELIBERATE EDITORIAL ACTS (`verdict-kill`, `:superseded`, curation); FORM
rather than origin (the MOC-hub demotion — a navigation stub is not an answer whoever wrote
it); and `@category_authority`, KEPT by explicit owner decision on the same date because a
category is an editorial classification, not an ingestion method.

**What is forbidden** is a weight keyed on a document's sourcer, capture tag, `source_type`,
or ingestion batch. Two failure modes no measurement catches: a provenance prior is a CLOSED
LOOP (demote unread material → it stays unread → cite the ratio as proof) and a RATCHET (a
weight shipped once by one model constrains every future receiver). Guarded by
`test/loopctl/knowledge/ranking_priors_test.exs` — "provenance priors are GONE".

**The golden-question eval below cannot catch a reintroduction.** Measured 2026-08-21: 1 of
124 docs in `priv/retrieval_eval/golden.jsonl` carries a harvest marker and NONE carry a
`source_type`, so removing both priors moved every metric by exactly `+0.000`. That green is
near-vacuous for this class of change — the unit guard is the real one.

**What would overturn this:** the owner saying so, or a conversion measurement that is
rank-stratified, uses a discriminator verified against the CURRENT corpus, and still shows a
durable gap. Reads-per-article is not that measurement.

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
  cost it. Cutover prod EXPLAIN + p95 artifact: GH #464. A cache MISS answers the in-code default
  `0` = the LEGACY column, so the boot prime is ORDERED, not merely fast: the supervised one-shot
  `Loopctl.SystemConfig.CachePrimer` primes synchronously inside its `start_link/1` and is listed in
  `Loopctl.Application.children/0` after `Loopctl.AdminRepo` and before `Oban` and the Endpoint
  (GH #588). Never make it a `Task` child or a `handle_continue/2` — both return to the supervisor
  immediately and restore the boot window in which every vector read silently used the legacy column.
  Production resolves the decision through `Loopctl.Embeddings.ReadPathBehaviour` (default impl
  `Loopctl.Embeddings.SystemConfigReadPath`, which also owns the flag-key string); `config/test.exs`
  points it at `Loopctl.MockEmbeddingReadPath`. **Tests must stub that mock per-process**
  (`Loopctl.DataCase.stub_embedding_read_path/0`, called for you by `stub_all_defaults/0`) and must
  NEVER write the flag — it is `:persistent_term`-cached VM-globally, so a write leaks across the whole
  node. `Loopctl.ConfigEmbeddingReadPathTest` fails the build on a second writer and on any
  `:embedding_read_path` config outside `config/test.exs`.
- **Reverting the flag is now an UNINDEXED read path on a cut-over install (GH #578).** The legacy
  `articles_embedding_hnsw_idx` (657 MB / 26 scans on prod 2026-08-04, vs 658 MB / 1,695 scans for the
  live side-table index, `pg_stat_user_indexes`) is retired: with `shared_buffers` at 1536 MB the two
  ~657 MB indexes evicted each other, and a cold vector search measured 8,044 ms of which 7,926 ms was
  `blk_read_time`. `articles.embedding` is still dual-WRITTEN — it stays the backfill/reconciliation
  source, and the column was NOT dropped — but on an install where the drop has run, setting the flag
  back to `0` puts reads on a column with no ANN index: a seq scan + top-N sort over the corpus, which
  trips `HeavyRead`'s per-read `SET LOCAL statement_timeout`. That cancel is a raised `Postgrex.Error`
  (57014) rendering `504 db_statement_timeout` — NOT `{:error, :heavy_read_overloaded}` (only the
  `TenantGate` concurrency shed produces that tuple) and so NOT the labelled keyword degrade, which
  matches the shed alone. Semantic search returns no results at all. A revert is therefore an INCIDENT
  action, not a routine toggle — rebuild the index FIRST (an explicit `CREATE INDEX CONCURRENTLY`, or
  `down/0` of `20260805120000_drop_legacy_articles_embedding_hnsw_index.exs`; raise
  `maintenance_work_mem` well above the 64 MB default or the ~657 MB build silently falls back
  to the slow on-disk path, wiki `753fbf69`) — and if you rebuilt via a rollback, flip the flag to `0`
  BEFORE the next migrate runs, since the rollback makes that migration PENDING again and the next
  deploy would re-drop the index you just rebuilt. The drop migration is GUARDED on that same flag read
  straight from `system_configs`, so an install still reading the legacy column keeps its index and a
  fresh self-hosted install is unaffected. `Loopctl.Embeddings.LegacyRetirement` discovers legacy
  indexes BY COLUMN, so an install that cuts over AFTER the migration ran still gets the leftover named
  in its scan map. `mix loopctl.embeddings revert` REFUSES while the legacy index is absent
  (capability-detected, `--force` to override) and `mix loopctl.embeddings status` reports its
  presence — but that refusal binds only where `mix` exists (source checkout / self-hosted from
  source). **A release ships no `mix`**, so on the hosted instance a revert goes through
  `bin/loopctl eval` or plain SQL and the guard never runs; there the runbook's rebuild-first
  ordering is the only thing standing between you and a tenant-wide semantic-search outage. Operator procedure:
  `docs/runbooks/embedding-dimension-cutover.md` — Retiring the legacy articles ANN index (the
  drop, the baseline above, and the `pg_stat_statements` query for the AFTER reading) and
  Reverting.
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
