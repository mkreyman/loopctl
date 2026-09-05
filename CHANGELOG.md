# Changelog

All notable changes to loopctl are documented here.

## [Unreleased] — 2026-08-21 — The provenance harvest runs on a cadence

### Added

- **Corpus mode B (`client_embedded`) — loopctl stores and ranks vectors it cannot read
  (US-43.3).** A corpus created with `mode: "client_embedded"` is indexed and searched
  without loopctl ever receiving the document text. **This is the property an operator
  points a regulated corpus at, so here is exactly what crosses the wire.**

  **What loopctl RECEIVES per chunk:** `source_ref` (your file path or identifier),
  `locator` (your opaque pointer — a page, a byte range, an EDI loop — stored verbatim),
  `vector` (the embedding you produced locally, whose length must equal the corpus's
  pinned `dim`), `content_hash` (yours), `ordinal`, and `snippet` ONLY if the corpus was
  created with `allow_snippets: true`.

  **What loopctl does NOT receive:** the chunk text — there is no parameter that accepts
  it, and a chunk carrying `text` is refused with `422 text_not_accepted` rather than
  silently ignored. And no snippet at all by default: `allow_snippets` defaults to FALSE
  for a `client_embedded` corpus (a snippet IS text the server would then hold). Ask for
  it explicitly if you want readable results.

  **What loopctl does NOT verify.** `content_hash` is treated as an opaque idempotency
  token, never as an integrity proof: holding no text, loopctl cannot check that it
  corresponds to the vector or to the file, and you own that correspondence. Nothing
  checks which model produced a vector either — that is not computable from a vector.
  What IS enforced is the vector's LENGTH against the corpus `dim`, at the API boundary
  and again by a database CHECK constraint — and that every element is representable in
  pgvector's float32 element type, refused as `422 vector_out_of_range` rather than
  silently truncated by the cast into a phantom dimension mismatch.

  **Retrieval is semantic-only,** because there is no text to index. `POST
  /api/v1/corpora/:id/search` takes `query_vector` (validated against the corpus `dim`)
  instead of `query`, and `meta.lanes` is `["semantic"]`. Every mode mismatch is a coded
  422 with a remedy — `query_string_not_accepted`, `query_vector_not_accepted`,
  `keyword_lane_unavailable`, `query_vector_dimension_mismatch`,
  `query_vector_out_of_range` — never an empty `200`, which an agent reads as an empty
  corpus. Send exactly ONE of `query` and `query_vector`: sending both is
  `422 ambiguous_query`, and an explicit `null` for either counts as absent, so a client
  that serializes omitted optionals as `null` is not routed to the wrong mode. An EMPTY
  ARRAY is not absent — it is a malformed vector and is refused as
  `422 invalid_query_vector` even when a `query` accompanies it. When the
  semantic lane is the only lane attempted — a `client_embedded` corpus, or
  `lanes: ["semantic"]` on a `server_embedded` one — and it fails, the answer is
  `502 semantic_lane_unavailable` carrying a bounded `details.reason`, never a raw
  provider term. Result and `meta` key sets are identical to a `server_embedded`
  corpus's, so a client branches on `meta`, not on the mode.

  **Batch sizing.** A request is bounded BOTH by its item count (`422 batch_too_large`)
  and by the request body byte cap, and on a `client_embedded` corpus it is the byte one
  that binds: a JSON-serialized vector costs roughly its dimension times 20 bytes, so a
  full-size batch of 768-dimension vectors is already over the cap. An over-size body is
  refused by the parser as `413 request_too_large`, which now carries a code and names
  the cap. Split the batch — indexing is idempotent, and `source_complete`'s manifest
  form keeps a document spanning several batches reconcilable.

  **Re-indexing in mode B.** `content_hash` and `vector` are two independent inputs the
  server cannot relate, so ANY rewrite stores the vector that came with it: a chunk whose
  only change is its `ordinal` or `snippet` adopts the new vector too (no provider call
  and no tokens, since none is needed in this mode). An item where the hash, snippet and
  ordinal are all unchanged still writes nothing — so ROTATE `content_hash` to publish a
  re-embedded vector for a chunk that did not otherwise move.

  **Operator impact:** none for existing corpora. `mode` is pinned at creation and
  immutable in BOTH directions — a `server_embedded` corpus can never become
  `client_embedded` or the reverse; changing tier is delete-and-re-index by design. No
  new environment variable and no migration.

- **API error responses default to JSON when a client sends no `Accept` header.** Error
  bodies are negotiated from `Accept`, and the fallback for a request that never
  negotiated one was HTML — so an error raised BEFORE the router (the body-size `413` is
  the live case, since `plug :accepts, ["json"]` has not run yet) reached a header-less
  API client as a web page. The fallback is now JSON. Browsers are unaffected: they send
  `Accept: text/html`, which still selects the HTML error page.

- **`GET /api/v1/channel/claims` — a non-destructive read of coordination claim state
  (#707).** Until now the only way to learn whether a handoff `ref` was claimed was to
  attempt the claim: `201` meant free, `409` meant taken. That probe is destructive on a
  fleet whose sessions share one `agent_id` — `channel_claim` is idempotent for the owning
  AGENT, so a probe issued while a PEER SESSION holds the ref returns that peer's claim as
  if it were the prober's own, and the `release` that tidies the probe up DELETES it,
  reopening a handoff someone is actively working. The read writes nothing. Agent role,
  tenant-scoped, not membership-gated (uniform with `GET /channel/locks`). MCP tool
  `channel_claims`, server 2.77.0. **Operator impact:** none required; existing callers are
  unaffected.

- **A dead-man's-switch over the nightly knowledge-lint consumers (#765 item 6).** Now
  that every queue class has an automatic consumer — drafts publish, `:generic_title`
  retitles, `:duplicate_capture` unpublishes, flagged conflicts are judged — the
  remaining failure is not a crash. It is a nightly pass that COMPLETES and disposes of
  nothing, night after night, because a step is broken, starved of its shared wall-clock
  reserve, or gated off. In the summary line and the audit event alike, that night is
  byte-identical to a night on a clean corpus. That is exactly how six consecutive nights
  of a dead conflict judge read as quiet success in #761.

  `Loopctl.Knowledge.IngestionHealth.detect_consumer_stalled_scan/1` reads the nightly
  `knowledge.lint_completed` audit events and flags two things: a consumer that applied
  ZERO for `knowledge_consumer_stall_runs` consecutive runs while work was waiting (or
  while the step could not act at all), and a nightly pass whose last completed run is
  older than `knowledge_consumer_pass_staleness_hours`. A genuinely clean, quiet corpus
  never alarms — a run that was offered nothing with every gate open neither starts nor
  extends a streak. **Operator impact, in four parts.**

  1. **It runs from `IngestionHealthWorker` (hourly), NOT from the nightly pass.** The
     failure it exists for includes the pass dying, and a detector hosted inside the pass
     cannot report that. `KnowledgeLintWorker`'s `timeout/1` and its budget arithmetic are
     untouched.
  2. **The deploy adds two migrations, neither of which pauses writes.** One widens the
     `ingestion_anomalies.anomaly_type` CHECK to admit `consumer_stalled` (catalog-only);
     its `down` RETAGS any recorded stall (resolved + archived, marked
     `rolled_back_from`) rather than deleting it, so the audit entries pointing at those
     rows stay resolvable without surfacing a mis-typed anomaly. The other creates
     `audit_log_knowledge_lint_idx`, a partial index over `entity_type =
     'knowledge_lint'`. `audit_log` is a RANGE-partitioned parent, where `CREATE INDEX
     CONCURRENTLY` is unsupported on the PARENT but supported per PARTITION — so the
     parent index is created `ON ONLY` and each partition's is built CONCURRENTLY and
     ATTACHed. It runs outside a DDL transaction and outside the migration lock; only the
     brief ATTACH blocks writes. Without the index the detector's cross-tenant read
     degrades to a sequential scan of the recent partitions on the 3-connection admin
     pool.
  3. **Three new tunables**, each resolving DB `system_config` row -> app config -> module
     default, so a window can be widened mid-incident without a deploy:
     `knowledge_consumer_stall_runs` (7, CLAMPED to HALF `audit_retention_days` — the
     streak window is double this number, so above half it could never fill and the
     detector would switch off in silence), `knowledge_consumer_pass_staleness_hours`
     (72), `knowledge_consumer_scan_limit`
     (20000). No new environment variables. Coverage is bounded by `audit_retention_days`
     (90 by default): a pass dead for longer than that leaves no events to judge.
  4. **A stall surfaces the way every other `ingestion_anomalies` detector does** — a
     `Logger.error`, an `ingestion_anomaly`/`detected` audit entry, an operator alert
     through `ScaleAlertDeliveryWorker` (a no-op when `SCALE_ALERT_WEBHOOK_URL` is unset),
     and the existing `knowledge.ingestion_anomaly_detected` webhook. It is recorded
     under one reserved sentinel `source_type` PER CONSUMER
     (`knowledge_lint_pass`, `knowledge_lint_drafts`, `knowledge_lint_duplicates`,
     `knowledge_lint_generic_titles`, `knowledge_lint_conflict_judge`), so `resolve` and
     `archive` on `/api/v1/ingestion_anomalies` work per consumer: archiving a
     deliberately paused draft drain does not blind the conflict judge. A stall
     auto-resolves only on POSITIVE evidence — the consumer applying again, the pass
     completing, or a whole window in which nothing was offered and no gate was blind or
     paused. A drain still PAUSED never auto-closes.

     The `knowledge_lint_pass` half is the exception to the per-tenant alert: its cause is
     the single global nightly cron, so one dead pass emits ONE system-scope
     `knowledge.lint_pass_stalled` operator alert per run carrying the affected-tenant
     count, not one page per tenant. The per-tenant anomaly rows and webhooks are
     unchanged.

### Changed

- **BREAKING: `POST /api/v1/knowledge/bulk-delete` no longer accepts `confirm`, and archiving
  by `tag` is now a two-step flow (#779).** The `confirm` parameter was a model-visible
  authorization argument: the same request that asked for the mutation also carried its own
  approval, so nothing outside the caller ever saw the proposal, and an agent that decided to
  archive every article carrying a tag also decided to confirm it. It is gone.

  **What breaks.** A request carrying a `confirm` key is refused with `400` and
  `error.code: "confirm_removed"` — deliberately refused rather than ignored, so a client that
  believes it is passing a gate learns the gate moved instead of silently sweeping a set. A
  `tag` call with neither `dry_run` nor a replay credential is refused with `400` and
  `error.code: "dry_run_required"`. Both codes are stable and machine-readable; the other 400s
  on this endpoint stay uncoded.

  **The new flow for `tag`, the same one the hard delete already used.** POST with
  `dry_run: true` to get `meta.would_affect` and a single-use, TTL-bounded `meta.token` frozen
  over the previewed id-set, then POST the same `tag` with that `token` to archive exactly that
  set. Rows that started matching the tag after the dry-run are never touched. A selector too
  large to freeze gets `meta.oversized` and `meta.confirm_hash` instead, echoed back with the
  same `tag`, and the server re-resolves and refuses on any drift.

  **Archive and delete proposals are not interchangeable.** They are minted with distinct token
  types, so an archive token replayed as a hard delete, or a delete token replayed as an
  archive, is a `400` invalid-token — the blast-radius escalation the two-step flow exists to
  prevent. Tokens remain single-use, TTL-bounded and tenant-scoped.

  **Unchanged:** the `article_ids` and `source_type`+`source_id` selectors still archive
  immediately with no token, because each names a set the caller already holds. The role gate
  is still `user`. The response shape is unchanged, including the backward-compatible
  `meta.counts`/`meta.results` block.

  **Client action:** upgrade `loopctl-mcp-server`; its `knowledge_bulk_delete` tool no longer
  declares `confirm`. A hand-rolled client must drop `confirm` from every bulk-delete call and
  add the dry-run/replay round trip for `tag` archives.

- **A draft is no longer held forever: the nightly pass now publishes held drafts, and
  the weekly draft-archiving sweep is parked (#765).** Before this, `status: :draft` had
  no automatic consumer at all — 113 articles were sitting in it on 2026-08-27, growing
  about 11 a night, and no read path serves a draft, so each was indistinguishable from a
  capture that never happened. `Loopctl.Knowledge.DraftConsumer` now runs inside the
  nightly knowledge-lint job: it assesses each eligible draft against the published
  corpus and publishes it, adding a `relates_to` edge to its nearest neighbour when the
  draft is a near-duplicate. **Operator impact, in four parts.**

  1. **`draft: true` (and ingestion's `publish: false`) has changed meaning.** It is now
     a HOLD, not a veto: an explicitly staged draft is recorded as such and published
     automatically once it is a week old; anything else drains after 48h. A caller that
     relied on a draft staying unpublished indefinitely must publish or delete it inside
     that window. The OpenAPI descriptions for both fields say so.
  2. **The deploy adds two migrations to `articles`.** `staged_draft_at` is a nullable
     column (catalog-only ALTER, no rewrite) that records the staging opt-in durably,
     because `metadata` is cast and whole-map-replaced by `PATCH /api/v1/knowledge/:id`.
     `articles_tenant_draft_inserted_id_idx` is a partial index over `status = 'draft'`
     built with `CREATE INDEX CONCURRENTLY`, which **cannot run inside a transaction** —
     the migration therefore disables the DDL transaction and the migration lock, and is
     re-runnable (it drops a leftover INVALID index from an interrupted build before
     creating), so a failed release does not wedge later deploys. It is small at hosted
     scale and does not block writes. It exists because the drain's candidate query runs
     on `AdminRepo`'s three-connection pool, which every authenticated request also uses.
  3. **The drain is paused without a deploy** by setting the
     `knowledge_draft_consumer_max_publishes` `SystemConfig` row to `0`; any positive
     value caps how many drafts one night may offer (default 30, chosen above the
     measured ~11-a-night producer rate so the backlog actually falls).
  4. **`DraftDuplicateSweepWorker` no longer runs.** It ARCHIVES a draft whose nearest
     published neighbour clears 0.95, and `:archived` is terminal — there is no unarchive
     path, so only a `user`-role PATCH brings a row back. An unattended writer may not
     take a terminal act, so the worker joins the parked set: its code and its 05:50
     Sunday schedule are unchanged, but it is filtered out of the live crontab unless an
     operator names it in `OBAN_UNPARK_CRONS`. **Weekly automatic archiving of duplicate
     drafts has therefore stopped**; the drafts it targeted are published and linked by
     the nightly consumer instead.

- **The hourly embedding reconciler no longer reads the whole `articles` heap to find
  nothing, and Oban prunes on a five-minute interval instead of every 30 seconds.** Both
  were measured on the hosted database over the 19 days to 2026-08-25. The reconciler's
  anti-join spent 168s across 275 runs (4.5% of everything that database did) and returned
  roughly one row per run, because `length(btrim(body)) > 0` had to detoast every body to
  answer a question about zero rows; the filter now rides a new partial index and the scan
  is index-only, 40,968 shared buffers and ~400 ms down to 1,181 and ~76 ms. The Oban
  pruner ran on the library's 30-second default against a SEVEN-DAY retention: 53,748
  calls, 457s, 12.1% of that database's total query time, to remove ~5,600 rows a day.
  **Operator impact:** the deploy adds `articles_tenant_embeddable_inserted_id_idx`
  (4.6 MB on the hosted corpus) via `CREATE INDEX CONCURRENTLY`, which cannot run inside a
  transaction and takes about a second at that size; it does not block writes. The
  migration is re-runnable — it drops a leftover INVALID index from an interrupted build
  before creating, so a failed release does not wedge later deploys. Terminal
  Oban jobs are now removed up to five minutes later than before, which is invisible
  against a seven-day `max_age`. No configuration change is required.

- **`POST /api/v1/channel/claims` now returns FOUR distinct 409 codes where it returned one
  (#707).** `already_claimed` previously covered four unrelated situations, and its body
  says "Do not retry the same ref; move on to other work" — advice that is correct for two
  of them and actively lossy for the other two. **Operator impact: a client branching on
  `error.code == "already_claimed"` for a superseded ref or an exhausted claim budget must
  be updated.** The HTTP status is 409 in all four cases; only the code and message differ.

  | code | meaning | what the caller should do |
  |---|---|---|
  | `already_claimed` | a peer holds a live claim, or you already completed this one | move on to another ref |
  | `claim_lease_expired` | the lease died without completion; the row is awaiting `ChannelClaimSweeper` | **retry THIS ref shortly** (carries `retry-after: 60`) |
  | `ref_superseded` | the ref's newest live post was superseded; nobody holds it | claim the successor handoff |
  | `claim_budget_exhausted` | you are at `max_concurrent_open_claims/0` | finish or release one of your own claims; the ref may well be free |

  `claim_lease_expired` is the one that was costing work: `GET /channel/claims` lists that
  same row and flags it expired, so before this split the read and the write told the caller
  opposite stories about the same ref.

- **A tag with surrounding whitespace is now rejected on every article write, not just a
  reserved one (#733 review).** `Article`'s tag pattern was `~r/^[a-zA-Z0-9_-]+$/`, and in PCRE
  `$` also matches immediately BEFORE a trailing newline, so `"elixir\n"` stored as a valid
  tag. It is now anchored `\A`/`\z`. A dirty tag was unrepairable once stored: it reads as free
  text everywhere downstream, and `IdempotencyTag.legacy?/1` refuses it, so the #583 promotion
  could never reach it either. **Operator impact:** a create/update carrying such a tag returns
  422 instead of storing it; the tag-shape rule is now published in the OpenAPI `tags`
  description and the 422 text. Whitespace-dirty tags already in a corpus are unaffected and
  still need a cleanup pass — the hosted corpus has none.

- **`mix loopctl.reserve_idempotency_tags` has a production entry point that is not a Mix
  task.** The sweep moved into `Loopctl.DataMigrations.ReserveIdempotencyTags`, which
  references no `Mix` at all, and `Loopctl.Release.reserve_idempotency_tags/1` runs it:

      bin/loopctl eval "Loopctl.Release.reserve_idempotency_tags()"
      bin/loopctl eval "Loopctl.Release.reserve_idempotency_tags(apply: true)"

  Dry run by default, like every other data migration here. The Mix task is unchanged as
  the development entry point and now just parses argv and delegates.

  **Operator impact:** run production sweeps through the release entry point. `mix` does not
  exist in a compiled release, and the old task reached `Mix.shell/0` on two per-row paths,
  so a production run had to be driven from outside and would raise the moment either path
  was hit. Driving it from outside is also slow in a way that is easy to miss: the sweep
  issues one compare-and-set UPDATE per changed row, so its cost is a network round trip per
  row — measured ~6.4 rows/s over a `fly proxy`, about three hours for 68,544 rows, against
  seconds from inside the datacenter. The release entry point starts only `AdminRepo`, so it
  adds no second Oban node to a running deployment.

- **`mix loopctl.reserve_idempotency_tags` now promotes the `email-` and `corpus-` families
  too (#733).** The #583 census missed both: bare `email-<sha1(message_id)[:12]>` (the inbox
  sourcer) and `corpus-<sha1(member ids)>` (the corpus synthesizer) are per-capture ids exactly
  like `url-`/`doc-`, but were absent from the legacy allowlist, so the backfill would have left
  that backlog in the ambiguous namespace forever. Both halves of the shape rule are unchanged,
  so only the digest-shaped tags promote — a topical `email-marketing` is still left alone, and
  `yt-` and `art-` stay unpromotable (the note above `@legacy_families` records why).
  **Operator impact:** re-run the task; it is idempotent, so rows promoted by an earlier run are
  untouched and only the newly-eligible families are written.

- **A tag with a trailing newline no longer satisfies the idempotency-tag shape rules.** Both
  matchers were anchored with `$`, which in PCRE also matches immediately before a trailing
  newline, so `idem-url-<digest>\n` stored as well-formed and a bare `email-<digest>\n` would
  have been promoted into the reserved namespace with the newline embedded — after which
  `--drop-legacy` deletes the only readable copy. Both anchors are now `\z`. **Operator impact:**
  a create/update carrying a RESERVED `idem-...` tag with a trailing newline is now rejected
  422 instead of stored. A tag without that prefix is unchanged at write time — the article
  tag-format check still admits it — and now stays put instead of promoting dirty, so any
  whitespace-dirty tags already in the corpus still need a cleanup pass.

- **Search ranking no longer keys on a document's provenance.** `Loopctl.Knowledge.RankingPriors`
  carried two priors keyed on where a document came from — a `source_type` authority table and a
  first-party/third-party split keyed on the sourcers' capture tags (`book-`/`url-`/`yt-`/`doc-`
  plus `web-article`/`newsletter`/`inbox-harvest`/`youtube`/`document`/`book`). Both are removed.
  `authority_factor/4` now reads `:category` alone; `provenance_authority/1` is gone.

  **Operator impact:** results may reorder on NEAR-TIES only. Both priors were bounded
  tie-breakers at the default strength 0.05 (a ~2.5% edge on an otherwise-equal pair, unable to
  flip a cross-lane consensus winner), so no strong-relevance ordering changes. On the hosted
  corpus 82,851 of 86,413 articles sat on the third-party side and now rank neutrally against the
  other 3,562. `mix loopctl.retrieval.eval` reports `+0.000` on every golden question — but that
  green is near-vacuous here, because only 1 of 124 golden docs carries a harvest marker and none
  carry a `source_type`. **No baseline change, no migration, no configuration change.**
  `:knowledge_authority_prior_enabled` and `:knowledge_hub_demotion_enabled` are unaffected.

  Why: the prior rested on a 26.7x reads-per-article gap whose denominator is the harvest's own
  volume, so it falls ~1/N mechanically. Rank-stratified surfaced-to-opened conversion converged
  by rank 3 and inverted by rank 4. Dead-doctrine demotion (`verdict-kill`, `:superseded`), the
  MOC-hub demotion, recency decay and category authority are all unchanged.

### Added

- **`POST /api/v1/knowledge/conflicts` — assert a conflict pair the system never flagged
  (agent+, #730).** `POST /knowledge/conflicts/resolve` could only reach pairs the
  auto-linker had flagged by cosine similarity, which is the wrong precondition for a
  DELIBERATE correction: the pair is minutes old so the nightly linker has not run, and a
  correction that argues about a conclusion may never cross the similarity threshold at all.
  The new endpoint creates the `:potential_conflict` link itself (`auto_generated: false`,
  `asserted: true`), carrying the claim — `classification`, a REQUIRED `evidence`, and an
  optional `proposed_authoritative_article_id`. The pair then appears in
  `GET /api/v1/knowledge/conflicts` with a new `origin` field (`"system"` / `"asserted"`)
  and, for an assertion, an `assertion` block; asserted pairs lead the queue, since they
  carry an argument rather than a similarity score.

  **Operator impact: no migration, no new environment variable, and no change to what any
  existing call does.** Two behaviours worth knowing:

  - `GET /api/v1/knowledge/conflicts` now returns asserted pairs alongside system-flagged
    ones, and asserted rows lead the ordering. Every row carries `origin`, and the endpoint
    takes `?origin=system` / `?origin=asserted` so a reviewer can read one provenance
    alone. `evidence` is capped at 4000 bytes (it is echoed on every row of that queue),
    and a principal may hold only 25 UNJUDGED assertions at once — both are `422`s, so no
    one caller decides what page 1 of the queue holds. The cap bounds pairs a principal
    OPENS, so re-asserting an already-flagged pair stays idempotent at the cap.
  - `POST /knowledge/conflicts/resolve` gains a `409 self_asserted_conflict`: the principal
    that asserted a pair may not also record its verdict. An asserted pair is named by its
    caller, so judging it is someone else's call — the same separation the `supersede`
    confidence cap already draws between recording a retirement and authorizing one. A
    system-flagged pair is unaffected; it carries no asserter.

  **Migration:** `20260821120000_widen_potential_conflict_partial_index_for_assertions`
  rebuilds `article_links_potential_conflict_idx` CONCURRENTLY so its partial predicate
  covers asserted rows too. Without it the conflict queue's `auto_generated OR asserted`
  filter no longer implies the index's `auto_generated`-only predicate, and the endpoint
  falls back to the seq scan + sort that 20260804220000 measured at 313 ms against the
  index's 0.131 ms. No downtime, no table lock, and it DROPs only a mismatched or INVALID
  catalog entry — an out-of-band prod build or a retry keeps its live index.

  **Behaviour change in the nightly `KnowledgeLintWorker`:** an asserted flag no longer
  pre-empts the system conflict pipeline. `promote_conflicts/1` ignores asserted rows when
  choosing candidates and UPGRADES an existing one in place (stamping `auto_generated` and
  the real similarity score, preserving the claim and its asserter), because the pair's
  `potential_conflict` slot is unique and an assertion sitting in it would otherwise mean
  the system flag could never be stamped — and therefore curated suppression could never
  fire for that pair again. The similarity-based judge skips asserted pairs outright: it
  can only ever record `:redundant`, a `dismiss` is terminal on record, and auto-dismissing
  a deliberate contradiction as redundancy would destroy the evidence the night it was
  raised. `LinkPruning` likewise requires SYSTEM provenance before releasing the
  high-similarity spare, so an assertion cannot trigger deletion of the `relates_to` edge
  the promoter needs.

  An assertion grants reachability and nothing else. It does NOT suppress either article
  from curated answers — `open_conflict_subquery/1` and `authoritative_curated?/2` still
  require `auto_generated: true`, or any key could retract any article from the governed
  answer path by disputing it — and it never overwrites a system flag's provenance.

- **`Loopctl.Workers.StructuralLinksWorker` — weekly `derived_from` harvest, `0 6 * * 0`.**
  US-42.1 shipped `Knowledge.StructuralLinks.harvest/2` with nothing running it, so only the
  one manual backfill ever produced source hubs; every source created since has had none.
  The worker fans out one job per ACTIVE tenant that has a published article, each gated by
  `FairShare`, and snoozes the tenant (rather than failing an attempt) when the corpus scan
  is shed. A tenant with no corpus is skipped outright, so a junk signup does not buy itself
  a weekly job insert and scan in perpetuity. Sunday 06:00 UTC puts
  it after the 05:00 MOC fan-out and the 05:50 draft sweep so the three weekly `:knowledge`
  passes do not contend for the lane.

  **Operator impact:** additive and idempotent — hubs resolve by `idempotency_key`, edges by
  their composite unique index, so a re-run over an unchanged corpus writes nothing. The
  unattended sibling floor is **25**, not the library default of 3: at 3 the hosted corpus
  yields 2,145 minted hubs against 25's 241, and the extra ~1,900 come from the smallest
  sources where a usable name is least likely. That floor is a DEPLOY-TIME constant
  (`:structural_links_min_siblings` for the worker, `:structural_hub_min_siblings` for an
  explicit call) — it is read from application config with no environment variable behind
  it, so changing it takes a code change and a deploy. No new environment variable, no
  migration.

- **The harvest report reconciles itself.** Each run now reports `sources_qualifying`,
  `distinct_hubs`, `shared_hubs`, `hubs_unattributed` and a `reconciled` verdict, recorded
  in the audit log under `knowledge.structural_links_harvested`. `reconciled: false` means
  a source landed on a hub that does not carry that source's tag — the corruption class
  that put 85 sources and 6,471 members on a single node before #724. Two sources sharing
  a hub that tags them BOTH is the ordinary dual-tagged shape and is reported as
  `shared_hubs`, not as a failure, so the verdict is not permanently false on a healthy
  corpus. A mismatch is reported, never raised — and the affected source's `derived_from`
  edges are REFUSED rather than written, so `hubs_unattributed` counts sources that were
  skipped, not edges that need cleaning up afterwards.

## [Unreleased] — 2026-08-20 — Work-breakdown import: a criterion must carry text

### Changed

- **`POST /api/v1/projects/:id/import` (and the merge variant) now reject an acceptance
  criterion carrying no text.** An entry with neither `description` nor `criterion` — or with
  only whitespace in both — returns `422` naming the offending index, e.g.
  `epics[0].stories[0].acceptance_criteria[1]: must carry a non-empty 'description' (or
  'criterion')`. Previously such an entry was accepted: the guard checked only that each
  member was an object, so `{}` and `{"note": "tbd"}` passed while the error message it
  would have printed claimed that `id` and `description` were both required. The message
  stated a contract the code did not hold, and the contract it stated was not the right one
  either — this endpoint has accepted `criterion` as an alternative to `description` since
  the 2026-03-28 discoverability change, and has never required `id`.

  **What did NOT change, deliberately:** an absent or empty `acceptance_criteria` list is
  still accepted. Importing a skeleton for pre-loopctl work is a supported path — the same
  payload carries `initial_agent_status: "reported_done"` precisely for completed historical
  work — and requiring criteria at the import boundary would break that to enforce a rule
  whose real home is the verify gate. `id` is still optional here.

  **Operator impact:** an integration that has been sending textless criteria will start
  getting a 422 where it previously got a 200. The criteria it was sending were being stored
  as entries with nothing for `verify_story` to be judged against, so the failure is
  surfacing existing bad data rather than creating a new restriction. No migration, no new
  environment variable.

### Added

- **`docs/user_stories/story.schema.json`** — the declared shape of an authored user story
  (`docs/user_stories/epic_N_name/us_N.M.json`), derived from all 240 committed stories
  rather than invented. It is stricter than the import payload on purpose (a non-empty
  criteria list, an `id` on every criterion), and `test/loopctl/user_story_schema_test.exs`
  binds the two so the half they share — that a criterion carries text — cannot drift apart.
  No new runtime dependency: the schema is a declaration, and the test is the only place it
  needs to be executable.

## [Unreleased] — 2026-08-07 — Story lifecycle capability delivery

### Added

- **`GET /api/v1/admin/knowledge/retrieval-metrics`** — per-tenant KB retrieval breakdown for
  superadmins. One row per tenant for a single day, so an operator can see **which** account's
  KB is unhealthy. Optional `day`, `window_seconds`, `active_only`; a malformed `day` or
  `window_seconds` is a 400, never a silent fall back to the default window.

  **It is a breakdown and deliberately never a roll-up, and the payload says so
  (`meta.aggregation: "none"`).** Each tenant's KB is a different corpus with a different size
  and traffic profile, so a total or mean across them describes no corpus that exists — a 2%
  read rate over 79,000 articles blended with 40% over 30 is not a fact about either, and the
  blend hides the account you were looking for. Platform-wide numbers stay in
  `GET /api/v1/admin/stats`, which counts inventory (summable) rather than retrieval quality
  (not).

  Tenants with no snapshot for the day are **included** with `snapshot: null` rather than
  omitted — a KB nobody queried, or a broken ingest, is a finding, and dropping the row hides
  the most interesting one. Rows carry their own `metric_version` and these can differ within
  one response, because a tenant not re-snapshotted since a definition change still carries
  the older one; compare a column across tenants only where the versions match.

  No new environment variables, and **no MCP tool**: cross-tenant reads are a superadmin
  capability, and pinning a superadmin key into the agent-facing MCP config to make a stats
  tool convenient would put a cross-tenant credential in every agent's reach. Call it with a
  superadmin key directly.


- **`metric_version` on retrieval-metric snapshots** (migration `20260820030000`, additive,
  `default 0`, no manual step). Every row now records which set of definitions produced it,
  and the value is published in the series payload.

  Three changes have already altered what a figure in this table *means*, each
  forward-looking and each leaving no mark on the row: `searched` was redefined from search
  calls to recorded surfaced results, infrastructure traffic began being excluded, and the
  disposition trio was rescoped onto `searches_scored`. A reader comparing across one of those
  boundaries was comparing definitions rather than days, with nothing in the data to reveal
  it. That is the mechanism behind every "these numbers don't make sense" report this table
  has produced.

  **Compare rows only within a version.** Existing rows report `0` — "written before the
  stamp, definitions unknown" — and are deliberately **not** backfilled to `1`, because
  claiming they were computed under current definitions is the exact false confidence the
  column exists to remove.

  The bump is enforced as far as it mechanically can be: a test pins the current version
  against the exact key set `compute/3` returns, so a field cannot be added, removed or
  renamed without failing. A change of *meaning* that keeps the same keys is not detectable
  that way, so the rule is written at the definition site: if a reader would draw a different
  conclusion from the same number, bump the version and re-snapshot the affected days.

### Changed

- **The KB analytics surfaces now count READS, not impressions — and several payload keys are
  renamed.** `article_access_events` holds two populations distinguished only by
  `access_type`: reads (`get`/`context`/`drill`, a body actually delivered) and impressions
  (`search`/`index`, one row per result the ranker surfaced). Impressions outrun reads roughly
  50:1, and four surfaces headlined an unfiltered count of both under names that promised
  reads. **Any dashboard reading these will report different — much smaller, and correct —
  numbers after this release.**

  Behaviour changes:

  - `knowledge_analytics_top` / `GET .../analytics/top-articles` — `access_type` now defaults
    to reads instead of every event. Pass `access_type=all` for the previous behaviour; single
    types are unchanged. It was ranking ranker output while documented as "which articles
    agents actually read".
  - `knowledge_unused_articles` — "unused" now means **not read**, where it previously meant
    "no event of any type". On the old definition an article the ranker surfaced constantly
    and nobody ever opened counted as *used*, so the dead-weight detector was blind to the
    largest class of dead weight.
  - `knowledge_agent_usage` — `total_reads` now counts reads. It counted every event, so the
    recall hook's key reported thousands of "reads" for a shell script that has deliberately
    read one article ever. `total_events` is added for the old figure.

  Renamed payload keys:

  | surface | was | now |
  |---|---|---|
  | `knowledge_article_stats` | `total_accesses` | `total_events` (plus a new `total_reads`) |
  | `knowledge_article_stats` | `unique_agents` | `unique_keys` |
  | `knowledge_analytics_top` rows | `unique_agents` | `unique_keys` |

  `unique_agents` was `count(DISTINCT api_key_id)`. That is not an agent count — the v2
  dispatch pattern mints one ephemeral key per dispatch, so one agent dispatched N times is N
  keys. The per-project `unique_agents` figure is unchanged: it joins `api_keys` and counts
  distinct `agent_id`, so it always meant what it said.

### Removed

- **The six `curated_*` / `retrieved_*` provenance fields** are gone from
  `GET /api/v1/knowledge/retrieval_metrics`, the `knowledge_retrieval_metrics` MCP tool, and
  the `retrieval_metric_snapshots` table (migration `20260820020000`, which drops six
  columns). Any consumer reading those keys must stop; nothing else on the payload changed.

  They could never report anything, and published a confident `0` instead of an absence:

  - **Nothing has ever been curated.** A source counts as curated only if its article has
    `curated_at` set, and that was NULL on all 85,325 production articles — the shipped
    `scope: :system` canonicals included. Every provenance decision therefore resolves
    `retrieved` over an empty candidate set.
  - **The buckets read a tag namespace the default path does not write.** They filtered
    `mode` for `hybrid_curated` / `hybrid_retrieved`, which only `knowledge_hybrid_search`
    produces, while the default search path has tagged the same decision `combined_curated` /
    `combined_retrieved` since the hybrid resolver moved onto it. At removal that was 8,090
    rows the metric could not see against 252 it could — roughly 97% of the traffic its own
    documentation claimed it made observable.

  No data is lost that could not be recomputed: every value derived from
  `article_access_events`, which is not pruned. Reintroducing the breakdown requires BOTH
  that something actually sets `curated_at` and that the filter match the `combined_*` tags.

- **`knowledge_hybrid_search` now says the curated branch is unreachable.** Its tool
  description told agents that a `curated` verdict means a canonical article answered and to
  trust it. That outcome cannot occur while no article is marked curated, so the description
  now says so and tells agents to read `retrieved` as the normal case rather than as evidence
  that a curated answer was considered and rejected. The line comes out when curation exists.

### Changed

- **`searches_reformulated` was measuring search density, not reformulation** — the figure it
  published was wrong by a wide margin and is now corrected. On the hosted instance it read
  **97%** where the session-scoped figure is **27%**. It is exposed by
  `GET /api/v1/knowledge/retrieval_metrics` and the `knowledge_retrieval_metrics` MCP tool,
  so any dashboard, report, or decision taken from it before this release should be re-read.

  Two independent causes, both now fixed:

  - It scoped "the same asker queried again" to `api_key_id`. Only two keys search a typical
    deployment — the recall hook's and the shared MCP key that every session and subagent
    authenticates with — and the median gap between consecutive searches on one of them is
    ~127 seconds. "Another search happened on this key inside the window" was therefore true
    almost always, by construction. It is now scoped to the **client session**.
  - It compared `search_id` only, never the query text, so a **verbatim retry** of a degraded
    search counted as a reformulation (142 of 311 flagged rows on one measured day). The query
    text is now compared.

  Two new columns, added by
  `20260820011500_add_scored_disposition_base_to_retrieval_snapshots` (additive, both
  `default 0`, no backfill, no manual step):

  - `searches_scored` — the base the dispositions now partition.
  - `searches_scored_with_follow_through` — of those, the ones that opened something.

  **The partition moved.** `searches_scored_with_follow_through + searches_reformulated +
  searches_quiet` now sums to `searches_scored`, **not** to `searches`. A search is scoreable
  only if it carries a session identity and comes from a channel able to react to a result;
  the recall hook and the session-start auto-query emit one distilled query per prompt and
  never see what came back, so they are excluded from this metric alone. They remain in every
  other denominator on that endpoint, precision included. Read `searches - searches_scored` as
  **n/a, never as zero**.

  The session identity is stamped forward-looking onto surfaced-result rows from the existing
  client-context header, so **snapshots for days before this release report
  `searches_scored: 0`** — which is how "not computed" is distinguished from "nothing scored".
  No historical row is rewritten.

### Added

- **Retroactive tagging** (`Loopctl.Workers.TagBackfillWorker`). Tags were LLM-generated once
  at ingest and nothing ever revisited them, so there was no way to improve an article's tags
  after capture at all. There is now.

  It re-tags against the corpus's **established vocabulary**, which is the entire point.
  Measured on the hosted instance: 684,883 topical tag instances across **60,141 distinct
  tags, of which 33,234 (55.3%) are used exactly once** — each capture invented plausible
  strings for ideas the corpus already had words for. Only 4.5% of that is spelling variants,
  so normalisation cannot fix it. Coverage is not the problem either (8.66 topical tags per
  article, 46 published articles below three), which is why a re-tagger that just generates
  more tags in isolation would make things worse.

  Concurrent (`Task.async_stream`, `:knowledge_tag_backfill_concurrency`, default 4),
  bounded per run, resumable via `metadata.retagged_at`, and **append-only** — an existing tag
  is never removed, because they carry provenance ids and the reserved `idem-` namespace a
  sourcer reads to know an article was already captured. A provider failure leaves the article
  eligible for the next run rather than silently stamping it as done.

  **Deliberately not on a cron**: one provider call per article, so it is started on purpose:

      Loopctl.Workers.TagBackfillWorker.enqueue_all_tenants(limit: 200)

### Changed

- **The nightly conflict judge now READS both articles instead of deciding on cosine
  similarity.** The novelty gate flags a pair when similarity clears a threshold, and the
  nightly lint then judged that pair on the same number — so every verdict came out
  `dismiss / redundant`, a genuine contradiction included. The judge said so itself in the
  evidence it wrote: *"similarity cannot distinguish agreement from disagreement."*
  Consequently `contradicts` sat at **0 edges** across the corpus while
  `find_contradiction_clusters/2` read it — a consumer with no producer, whose report could
  only ever be empty.

  `Loopctl.Knowledge.ConflictJudge` classifies a pair as `redundant`, `contradictory` or
  `complementary`, and a `contradictory` verdict now writes the `contradicts` edge that the
  lint report has always been waiting for.

  **Additive only.** The disposition stays `dismiss` whatever the classification: `supersede`
  and `merge` defer to the nightly executor and a `:high` supersede authorizes an unattended
  retirement, and deciding which of two contradicting articles is right is not a call an
  unattended judge is entitled to make. An edge appears and a row appears; nothing is
  retired, rewritten or hidden.

  **Operator impact: one provider call per FLAGGED PAIR** — bounded by the existing nightly
  judgement cap (2000) and ~450/day in practice, not per search. Judgements run concurrently
  (`:knowledge_conflict_judge_concurrency`, default 4) because a sequential run of a 2000-pair
  catch-up could not finish in a nightly window. Every failure path — no LLM key, provider
  error, unparseable reply, an article deleted between the flag and the judgement — falls back
  to the previous similarity verdict, so a deployment that cannot use it is exactly where it
  was. Set `:knowledge_conflict_judge_enabled` to `false` to keep the old behaviour outright.

### Fixed

- **`articles.consolidation_retracted_at`** — a durable, non-cast marker that the nightly
  consolidation pass retracted an article. `DraftDuplicateSweepWorker` must not re-archive a
  draft consolidation deliberately unpublished, and the only record of that authorship was
  the retention-bounded `audit_log`; past `:audit_retention_days` the sweep could not tell
  consolidation's retraction from a human draft.

  **The migration BACKFILLS from the audit_log**, which is a one-time opportunity — after the
  next partition drop those rows are unprovable forever. The sweep's fail-closed horizon
  stays as the backstop for anything already past retention when this ran.

  A COLUMN rather than a `metadata` key, for the `stories.lifecycle_entered_at` reason:
  `metadata` is cast and whole-map-replaced by `PATCH`, so one ordinary update would erase
  it. Never add it to a `cast` list — a test asserts that against the source.

  The `ALTER` is catalog-only (nullable, no default), so no table rewrite.

- **`Loopctl.Knowledge.Article` now owns the tag rule.** `tag_pattern/0` and
  `max_tag_length/0` are public, and `Tagger` and `ContentIngestionWorker` read them instead
  of keeping copies. There were three hand-synced copies and they disagreed — `Article` and
  the ingestion worker allowed `[a-zA-Z0-9_-]` up to 100, the re-tagger lowercase up to 64.
  That matters because `TagBackfillWorker` persists with `update_all` and runs no changeset,
  so a looser rule stores rows the changeset rejects, surfacing later as a 422 on an
  unrelated caller's PATCH. The re-tagger stays STRICTER (lowercase start, on already
  normalised input) — stricter is fine, different was the bug.



- **A migration slower than the database's `idle_in_transaction_session_timeout` no longer
  fails the release command after succeeding.** `Ecto.Migrator` takes its advisory lock
  inside a transaction and leaves that connection idle for the whole run, so Postgres kills
  it once the migration outlives the timeout — the migration itself commits, then the
  release command exits non-zero and the deploy aborts.

  Observed on 2026-08-17: the `articles.search_vector` rebuild logged
  `== Migrated 20260817212906 in 59.8s` against a 60000ms timeout, died with
  `FATAL 25P03` in `do_lock_for_migrations`, and Fly aborted the deployment. Production was
  left running the NEW schema with the PREVIOUS release's code — harmless only because that
  change was additive.

  `Loopctl.Release.migrate/0` and `rollback/1` now disable the timeout for the migrator's
  own connections. **Scoped to the migrator**: the timeout stays on for the application,
  where a connection stuck idle in a transaction holds locks and blocks vacuum. No operator
  action and no database setting change.

### Added

- **A second-stage reranking seam for combined search** (`Loopctl.Knowledge.Reranker`),
  **disabled by default** (`:knowledge_reranker_enabled` is `false`, `:knowledge_reranker`
  is the no-op). Nothing changes for any deployment that does not turn it on, and turning it
  on puts an LLM call on every search and every `/recall`.

  It reorders the returned page rather than the fused pool, and it fails OPEN: no key, a
  provider error, a timeout, a malformed reply, or an ordering that is not a permutation of
  the page all return the fused order unchanged. A reranker can permute results, never
  inject, drop or edit one.

  Measured on the retrieval eval it improves every aggregate (MRR +0.105, nDCG@5 +0.087,
  answered +1) AND drives two multi-hop questions from recall@5 1.0 to 0.0, because it
  re-applies the surface-similarity judgement the graph lane exists to bypass. That is why it
  ships off; the reasoning and the overturn condition are in
  `docs/research/kb-retrieval-improvement-plan.md`.

### Changed

- **`articles.tags` are now part of the keyword index**, at weight `C` (below title `A` and
  body `B`). `articles.search_vector` has indexed title and body since April and never
  tags; sampling 3,000 published articles found **59.9% of topical tag instances carry
  vocabulary appearing nowhere in that article's own title or body**, so roughly three
  fifths of the curated topical vocabulary was unsearchable by keyword.

  Machine-minted provenance tag prefixes (`url-`, `yt-`, `book-`, `doc-`, `pp-`, `chunk-`,
  `chapter-`, `part-`, the reserved `idem-` namespace, and the rest of
  `Loopctl.Knowledge.ProvenanceTags.prefixes/0`) are excluded by the new IMMUTABLE
  `loopctl_searchable_tags(text[])` function. Postgres tokenizes a hyphenated word into the
  compound and its parts, so indexing those would put the bare lexemes `url`, `book`, `doc`,
  `idem` on tens of thousands of rows, and those are ordinary query words.

  That list also now backs `KnowledgeMocWorker`'s hub-topic exclusion, which previously
  owned it. `chapter-` and `part-` are new to it — the same chunk-coordinate class as `pp-`
  and `chunk-` — so those tags stop being eligible as MOC hub topics as well.

  **DEPLOY IMPACT — read before rolling this out.** The migration DROPs and re-ADDs the
  generated column and rebuilds its GIN index, which takes an ACCESS EXCLUSIVE lock on
  `articles`: reads AND writes to that table block for the duration. Measured on the hosted
  instance 2026-08-17: 85,294 rows, 138 MB heap, 59 MB FTS index — expect roughly a minute
  or two. Schedule it accordingly; there is no online path for a generated column. The
  migration is reversible (`down` rebuilds the column without tags).

- **Combined search now fuses a third lane of link-graph neighbours**, and it is ON by
  default (`:knowledge_rrf_graph_lane_enabled` flips `false` -> `true`,
  `:knowledge_rrf_graph_weight` `0.25` -> `0.15`). The lane takes the top merged candidates
  as seeds and adds their one-hop `article_links` neighbours as a third RRF input, so a
  document that no query term reaches but that hangs off a document the query does reach can
  now be retrieved at all.

  **Operator impact: one additional read per combined search.** It is tenant-scoped, capped
  at 200 link rows, routed to the heavy-read pool with its own statement timeout, and shed to
  an empty lane when a tenant is over its in-flight cap — never a 429, never the admin pool.
  `search_combined/3` is the default search path, so this is on every search and every
  `/recall`. Set `:knowledge_rrf_graph_lane_enabled` to `false` to restore the previous
  behaviour exactly.

  The weight was chosen by sweeping it on the eval, not by argument: 0.15 is the largest
  value that gains multi-hop answers while costing no question its answer, and the old 0.25
  would have cost one. Numbers and method in `docs/research/kb-retrieval-improvement-plan.md`.

### Added

- **Every search result now carries a snippet**, plus a `snippet_source` naming which kind
  it is (`highlight` | `lead`). `snippet` is a `ts_headline` fragment and therefore came
  ONLY from the keyword lane, so a result the query did not lexically match — precisely
  what the semantic lane exists to find — arrived with no snippet key at all. The rows
  most in need of an explanatory line were exactly the ones that had none, and an agent
  handed a bare title either opens it blindly or ignores it. A `lead` is an extract of the
  article's own opening prose, skipping the front matter that would otherwise fill it
  (99 articles in one corpus begin with an auto-extraction banner, and a lead built from
  that explains nothing while looking like it does).

  Affects `GET /api/v1/knowledge/search` (semantic and combined modes) and
  `POST /api/v1/recall`, so the injected recall hook gets it too. Additive: consumers that
  ignore `snippet_source` are unaffected, but one that used the ABSENCE of `snippet` to
  detect a semantic-only hit should now read `snippet_source == "lead"`. The fill is
  bounded to the returned page and runs on the HeavyRead pool, which sheds under load — a
  shed backfill costs a snippet, never a result. System-scope canonicals are the one
  exception: their NULL `tenant_id` cannot satisfy the heavy-read tenant guard, so those
  bodies are read through AdminRepo, and only for the ids the tenant-scoped read left.

- **A read now records WHICH search surfaced it**, on two new
  `article_access_events` columns (`origin_search_id`, `origin_attribution`) resolved
  SERVER-SIDE at write time and never accepted from a caller — the same rule
  `metadata.search_id` already follows (#582), because an origin a caller can assert is
  follow-through a caller can manufacture. `GET /api/v1/knowledge/analytics/retrieval-metrics`
  and the `knowledge_retrieval_metrics` MCP tool gain five fields, and
  `retrieval_metric_snapshots` gains the columns behind them (both migrations are additive,
  default 0, no manual step; historical rows read 0 because the data did not exist, not
  because it was zero).

  Why it matters to an operator reading the existing series: `followed_through` correlates a
  search and an open on `api_key_id`, and the injected recall hook searches under a
  DIFFERENT key from the session that reads it — measured 2026-08-17, the hook's key made
  1,071 searches and 1 read ever, while the session key made 2,535 reads. So the channel
  carrying 71% of all search volume has always scored a structural ZERO there, meaning
  UNMEASURABLE rather than unread. `cross_key_opens` is that population. `direct_opens` is
  an agent going straight to an article by link or cited id, previously indistinguishable
  from "surfaced and ignored" — close to its opposite. Unit warning: these count READS,
  while `followed_through` counts SURFACED RESULTS later opened; they are not comparable and
  neither replaces the other, so the existing series is unchanged and remains valid across
  this migration. Both open counters drop reads whose SURFACING search declared an infra
  entrypoint (`smoke`, `skill-eval`), so they describe the same population as
  `searched`/`searches` rather than a wider one.

  `searches_with_follow_through` / `searches_reformulated` / `searches_quiet` now partition
  `searches`. Treating every not-opened search as a failure is wrong — an agent answered by
  the result snippet correctly opens nothing, and that is a success. A reformulation — the
  same key issuing a LATER SEARCH CALL in the window, having opened nothing (compared on
  search identity, so a verbatim retry counts) — is the closest thing to an unambiguous
  failure in that bucket, so it is split out; `quiet` is STILL a mixture of
  "the snippet sufficed" and "the rows were ignored", and this release does not separate
  them.

- **Vector-read responses now disclose whether the read ran with `hnsw.iterative_scan`,**
  on a new `meta.ann_iterative_scan` (`off` | `applied` |
  `unavailable`) plus an `ann_iterative_scan_reason` alongside `unavailable` only.
  It is returned by `GET /api/v1/knowledge/search` in the semantic and combined
  modes, by `GET /api/v1/knowledge/articles/:id/suggested_links`, and by
  `POST /api/v1/memory/recall` (and the `memory` half of
  `POST /api/v1/recall`) on any semantic path that scans the HNSW index — absent on the
  ILIKE fallback and on an `include_superseded` recall, neither of which scans it, so
  absence never means the fallback ran. One field name, one vocabulary, one derivation
  across every surface. The vector reads that have NO response envelope because their
  consequence is a write — the novelty gate, the memory near-dup dedup scan — instead log
  one throttled warning per path when they run degraded. This
  matters when an operator has enabled iterative scan (SystemConfig `hnsw_iterative_scan`)
  and the read nonetheless runs without it — either because the backend capability probe was
  inconclusive (a pool-checkout timeout, a DB restart) and FAILED CLOSED, or because the
  connected pgvector conclusively does not support the setting (older than 0.8, or the
  extension is absent). Because the ANN applies
  `tenant_id` as a residual filter after the index returns its batch, such a read may
  under-return, and until now nothing in the response said so; a short result set was
  indistinguishable from an empty corpus. On memory recall that is the harder miss to
  catch — `meta.underfilled` was already true for a genuinely sparse scope, so it could
  not distinguish the two, and nothing downstream cross-checks a recall. The field speaks
  only to the tenant residual: memory's `subject_id` is filtered outside the index scan,
  so subject-level under-return is unaffected by it and stays `meta.underfilled`'s job.
  The read behaviour is UNCHANGED and failing closed
  remains correct — this only tells the caller. The `reason` names WHICH cause, because the
  response differs: an inconclusive probe self-heals on the next conclusive one (worst case
  roughly a minute per node), an unsupported pgvector stands until the extension is
  upgraded. Treat `unavailable` like
  `pool_capped: true`. **This state has not been observed in production;** it is a disclosed
  code path, not a reported incident. Instances at the shipped default (`off`) see
  `ann_iterative_scan: "off"` and are otherwise unaffected.

### Fixed

- **A tenant audit-key rotation now takes effect FLEET-WIDE, not just on the machine that
  performed it.** The per-tenant Ed25519 signing key is cached in ETS, which is node-local, so
  on a multi-machine deployment every OTHER node kept signing capability tokens and Signed Tree
  Heads with the retired key until its own 5-minute entry expired. Those signatures do not
  verify — a capability signed by a superseded key is recorded as `capability_forged`
  (`byzantine: true`) — so a routine, documented operation manufactured forgery evidence
  across the fleet for minutes. Rotation now broadcasts the invalidation over the existing
  cluster PubSub (the same mechanism the API-key and LLM-settings caches already used), and
  as a second line of defence a mint verifies its own signature against the public key the
  tenant advertises, busting its cache and re-signing once if they disagree. **No operator
  action, no configuration change**; a single-machine deployment was never affected.

- **The duplicate-consolidation similarity threshold now honours a deliberate hard-disable
  instead of silently re-enabling auto-unpublish.** Setting the knob to an impossible value —
  `knowledge_consolidation_min_duplicate_similarity_pct` at 100 or more, or the app-config
  float at 1.0 or more — is how an operator stops the nightly auto-unpublish mid-incident
  without a deploy. It was treated as out-of-range and replaced by the 0.80 default, i.e. the
  class the operator had just switched off carried on running at its normal threshold. Such a
  value is now honoured: no similarity can reach it, so nothing auto-applies, and each
  withheld group says so by name in the log. Values at or below 0 still fall back to the
  default (0 would turn the corroboration check OFF rather than disable the class) and now say
  so — including a stored `-1`, which previously collided with the "no row configured"
  sentinel and vanished without a word.

- **A missing audit signing key is no longer recorded as a forged capability.** When a
  presented capability's signature could not be checked AT ALL — the tenant's
  `audit_signing_public_key` was cleared, or was replaced out of band without a
  `tenant_audit_key_history` row covering the token's `issued_at` — the refusal was written
  to the append-only, hash-chained audit log as `capability_forged` with
  `payload.byzantine: true`. That is a permanent accusation against an agent that did
  nothing wrong: an authentic token fails identically in that key state, so the reason
  carried no information about the caller, and an append-only record cannot be retracted.
  Such a refusal is now `capability_key_unavailable` with `payload.byzantine: false` and
  reason `signing_key_unavailable`. A signature that fails against a key that IS available
  is still `capability_forged` / `byzantine: true` — and the two are now told apart by
  whether the tenant's advertised public key still CORRESPONDS to the private key it signs
  with, not by `audit_key_rotated_at` alone (an out-of-band `UPDATE` of the key leaves that
  timestamp untouched, so it read every outstanding token as a forgery). `mint` refuses
  symmetrically: it verifies its own signature against the advertised key before issuing,
  so a rotation whose new secret is not deployed yet fails the MINT instead of issuing a
  token that will later be called forged. **New response:** the operation still fails
  closed, but with `503 capability_key_unavailable` and NO `Retry-After` rather than `403
  missing_capability` — the latter's documented remedy is `recover-cap`, which mints
  through the same unusable key, so callers were sent round a loop only an operator can
  break. **Operator action:** if you see
  `capability_key_unavailable`, restore or re-archive the tenant's audit key; existing
  `capability_forged` entries written before this change may be false positives for
  tenants whose key was cleared or rotated out of band, and should be re-read against the
  tenant's key history rather than treated as evidence.

- **A claim that cannot mint its capability no longer commits.** For a tenant with an audit
  signing key, `POST /stories/:id/claim` minted the `start_cap` AFTER its transaction
  committed. If minting failed (an unreachable secret store), the story was claimed with no
  capability and no way forward: `start` demands one, `GET /stories/:id/capabilities` only
  delivers tokens already minted, and `recover-cap` needs an `implementer_dispatch_id` that
  a legacy bearer claim never records. Minting is now part of the claim transaction, so the
  claim either delivers a usable capability or does not happen. **New responses:** `503
  capability_mint_failed` with a `Retry-After` when the condition clears on its own — the
  secret store merely blipped, or a rotation's new private half is not deployed yet — and
  `503 capability_key_unavailable` with NO `Retry-After` when the audit key is absent or
  corrupt, which no amount of retrying can clear. A claim whose own audit or webhook step
  fails now answers `500 claim_failed` (nothing was claimed; retry) instead of crashing the
  request. Keyless (pre-v2) tenants are unaffected — they claim with no capability, as
  before.

- **Capability recovery binds to the CALLER's dispatch lineage, so it works after a crash.**
  `POST /stories/:id/recover-cap` minted a `start_cap` bound to the lineage recorded on the
  story's ORIGINAL implementer dispatch. A capability matches its lineage exactly, and the
  situation recovery exists for is precisely the one where that session died and the agent
  came back under a new dispatch — so the recovered token was unconsumable by the only
  principal entitled to spend it. It now binds to the caller's server-resolved lineage,
  which grants nothing new (the caller is already verified as the story's assigned agent,
  and `start` re-checks that). **Behaviour changes:** an implementer dispatch that has
  merely EXPIRED no longer blocks recovery (a revoked one still does, as `422
  dispatch_revoked`); and a caller whose key no dispatch minted is refused with `409
  caller_lineage_required` on dispatch-minted work. Recovery deliberately never rewrites
  `implementer_dispatch_id`, and it does NOT require the caller to share a custody ROOT with
  it: the crash it recovers from can take the whole tree with it, and the story's assigned
  agent plus the `assigned_agent_id` equality every L4 gate runs is what keeps a recovered
  agent from reporting its own work. Every refusal from this endpoint now carries a stable `error.code`, the catch-all
  no longer renders an internal error term into the response body (it is logged instead),
  and a mint failure answers with the same status and code as `claim` does (`503`, not the
  previous `422 cap_mint_failed`).

- **The egress pin cache is bounded per tenant, not only globally.** Every host it holds
  arrives from tenant-writable input (a webhook destination, an ingest URL, a chat base
  url), so one tenant registering fresh hostnames in a loop could fill the single global
  50k-entry cap and get every OTHER tenant's next classification refused admission — a
  shared cache turned into a cross-tenant denial. Admission is now also capped per tenant.
  Past the cap new hosts are simply re-classified on demand (a `Logger.warning` names the
  tenant); no verdict changes. Each SHAPE has its own per-tenant budget, because they grow
  for different reasons: pins and the negative cache for hosts that fail to resolve are
  capped separately (so a run of DNS misses cannot starve a tenant's real pins, and neither
  shape can reach the global cap alone), while a scope's `local_only` marking is bounded by
  the tenant's scope count rather than by request volume. The global cap still bounds all
  three.

- **The story lifecycle is completable again for tenants with an audit signing key (#621).**
  Every tenant created through the current signup flow has one, and for those tenants the
  capability layer rejected start/report/verify because NO client-facing path ever handed the
  caller a capability token: the tokens were minted at each transition and discarded. The
  lifecycle has been unusable over the API since 2026-04-12; it went unnoticed because recent
  work flowed through pull requests rather than the story lifecycle, and because the test
  suite only exercised the keyless path, where capabilities are not enforced.
  **What changed for clients:** the `claim` response now carries a `capability` object whose
  `cap_id` must be presented as the `capability` field on `start`. That is the ONLY capability
  a client ever has to carry. A new `GET /api/v1/stories/:id/capabilities` returns the live
  tokens already issued to the caller for a story — the recovery path when the claim response
  is lost to a crash or timeout; it never mints. `loopctl-mcp-server` handles all of this
  automatically; upgrade it rather than plumbing tokens by hand. Claiming with a
  dispatch-minted key now also records `implementer_dispatch_id`, without which every
  downstream lineage check silently degraded to plain agent-id equality.

- **`report` and `verify` no longer require a capability token, and no `report_cap` or
  `verify_cap` is minted.** Neither could have worked. A capability binds to exactly one
  dispatch lineage, but both transitions exist precisely so that a DIFFERENT principal
  performs them: the `report_cap` authorized the one principal forbidden to report, and the
  `verify_cap` was bound to whichever dispatch loopctl selected as verifier — which may be an
  `:agent`-role dispatch that the `exact_role: :orchestrator` verify endpoint rejects, or
  nothing at all in a tenant whose dispatches share one root, and which a legacy env-var
  orchestrator key (lineage `[]`) can never hold. The bulk `verify-all` path never sent a cap
  at all and silently returned `verified_count: 0`. Both transitions are gated by structural
  lineage separation plus the `exact_role` plugs: `verify` now compares the CALLER's
  server-resolved dispatch lineage against the implementer's, exactly as `report` does, so an
  orchestrator key inside the implementer's own dispatch chain is refused with `409
  self_verify_blocked` even when its `agent_id` differs. That check runs on every path,
  including the common one where the optional `request-review` was never called; the
  loopctl-selected verifier is still recorded and compared in addition whenever it exists.
  See `docs/chain-of-custody-v2.md` §5.2.

- **An unusable capability no longer halts the whole tenant.** Any rejected token produced
  `{:cap_rejected, _}`, which custody-halts the tenant and 503s every subsequent request from
  it — so one agent letting a token pass its 1-hour TTL took down every other agent in the
  tenant. **No capability rejection halts a tenant any more** — not a forged signature, not a
  double-spent token (see the 2026-07-24 entry below, which supersedes an earlier draft of
  this line). Every one of them is an ordinary 403, and every one is recorded in the
  hash-chained audit log with the `cap_id`, api key and agent: expiry and lineage drift as
  `capability_refused`, a signature that failed to verify as `capability_forged`, a
  double-spent token as `capability_replayed`. Replay gets its own action, and
  `payload.byzantine: false`, because an ordinary retry produces it — recording a stale token
  as a forgery wrote a permanent accusation into an append-only log, and a consumer keying
  off the flag rather than the action read it that way too. That recording
  used to run the wrong way round — the benign refusals were chained and the forged ones
  left only a log line — so a forged signature is now durable rather than dependent on log
  retention. Alert on the RATE of the
  `[:loopctl, :custody, :cap_rejected]` telemetry event; a single occurrence is not a signal.
  Relatedly, **rotating a tenant's audit signing key no longer invalidates outstanding
  capability tokens**: verification now also accepts the historical key whose
  `[rotated_in, rotated_out)` window covers the token's `issued_at`. Without that, a routine
  rotation made every live token `invalid_signature` — which IS byzantine, so a documented
  operator action custody-halted the tenant.

- **Capability refusals return their documented 403 instead of a 500.** The controllers had no
  clause for the capability layer's own error shapes, so a missing or rejected token raised a
  CaseClauseError — making a correct refusal indistinguishable from a crash in logs and alerts.
  A non-UUID `capability` value likewise 500'd (`Ecto.Query.CastError`) instead of 403ing.

- **A dispatch may now only be minted inside the caller's own lineage.** `POST
  /api/v1/dispatches` accepted a parentless request from any orchestrator-or-above key, and
  accepted any active dispatch in the tenant as `parent_dispatch_id`. Both let a caller place
  itself in a lineage unrelated to its own, which is the separation the L4 custody gates read
  as "an independent principal". Two new 403s: `root_dispatch_forbidden` when a key that was
  itself minted by a dispatch sends no `parent_dispatch_id` (only a key no dispatch minted —
  the tenant's operator key, rooted in the human anchor — may start a lineage tree), and
  `parent_outside_caller_lineage` when the named parent is not the caller's own dispatch or a
  descendant of it. "Operator key" is decided POSITIVELY — `role: :user` AND not minted by a
  dispatch — because an absent lineage also describes a legacy long-lived key. **What changed
  for clients:** a sub-agent that used to mint a fresh root must now pass its own dispatch id as
  `parent_dispatch_id` (the 403 body returns it as `remediation.your_dispatch_id`); a legacy
  `LOOPCTL_ORCH_KEY` can no longer mint a ROOT — use the tenant's `user`-role operator key —
  but it may still mint BENEATH any active dispatch, which is how it obtains a lineage during
  the deprecation window. Minting a second, independently-rooted tree remains worthwhile
  (`select_verifier/3` prefers a different-root candidate and reports `no_independent_root`
  without one), but it is not required for liveness: the verify gate compares the caller at
  chain distance, so a sibling verifier under the same root certifies fine. Both refusals
  are logged as `lineage_ceiling_refused` and emit
  `[:loopctl, :custody, :lineage_ceiling_refused]`.

- **The lineage ceiling also covers API-key minting.** A plain API key is minted by no
  dispatch, so it carries no lineage — the same shape the rule above admits as "may start a
  new tree". A caller whose own key came from a dispatch could therefore mint itself a plain
  key at `POST /api/v1/api_keys` (or rotate an existing one) and use it to start the
  independent root it had just been refused. Both raw-key-minting actions —
  `POST /api/v1/api_keys` and `POST /api/v1/api_keys/:id/rotate` — now return
  `403 api_key_mint_forbidden` to a caller that carries a dispatch lineage, logged and
  counted under the same `lineage_ceiling_refused` name. **What changed for clients:** an
  agent or orchestrator running under a dispatch cannot create long-lived API keys; mint a
  dispatch beneath its own instead (`POST /api/v1/dispatches` with `parent_dispatch_id`,
  returned in the 403 as `remediation.your_dispatch_id`), which yields an ephemeral key
  inside its subtree. The tenant's operator key and legacy env-var keys — neither of which a
  dispatch minted — are unaffected, as are `GET /api/v1/api_keys` and key revocation.
  `loopctl-mcp-server`'s `dispatch` tool documentation has been corrected accordingly: it
  still said to omit `parent_dispatch_id` for a root dispatch, which is now a 403.
  A revoked dispatch no longer reads as "no lineage" for this check — the ceiling asks whether
  the principal was EVER inside a lineage, not whether its dispatch is still live.
  **Operator action required:** this closes the mint going forward but retires nothing the
  open window already produced. `api_keys` records no minter, so a plain key created by a
  dispatch-minted caller before this release is indistinguishable from the tenant's operator
  key and still holds an independent root. Review `GET /api/v1/api_keys` for every tenant, and
  revoke any `:user`-role key you cannot account for as the human-anchored operator key.

- **Verifier selection is seeded from a server-side secret.** The rotating verifier's index was
  derived from the tenant's audit signing PUBLIC key, which `/.well-known/loopctl` serves
  unauthenticated, while the candidate pool is listable by any agent key — so the choice was
  reproducible by the parties it chooses between. It is now an HMAC keyed by the tenant's audit
  signing PRIVATE key, domain-separated and bound to the tenant and story. **Operator impact:**
  a tenant whose audit signing key is not provisioned (or an unreachable secret store) now has
  no seed and none is invented — selection fails closed, the story is flagged `verifier_needed`,
  and a `verifier_not_assigned` entry with reason `verifier_seed_unavailable` is written to the
  audit chain plus an `audit_chain_append_failed`-style error log and a
  `[:loopctl, :custody, :verifier_seed_unavailable]` telemetry counter — alert on it, since a
  secret-store outage fires it on every request-review deployment-wide. Verification itself is
  unaffected: the verify gate enforces lineage separation independently, and now refuses an
  unlineaged caller outright on a dispatch-minted story rather than falling back to agent-id
  inequality. Provision the tenant's audit key to restore automatic selection.

- **Backfill can no longer be used to certify work that ran inside loopctl.** `POST
  /stories/:id/backfill` (and the bulk `mark-complete`) refused stories carrying dispatch
  markers, but `force-unclaim` clears `assigned_agent_id`, and a story claimed with a key that
  no dispatch minted never records an implementer dispatch — so a worked story could be
  returned to a state indistinguishable from pre-loopctl work and then marked verified with no
  report, review record or independent verifier. Unclaim, force-unclaim and both reject
  auto-resets (single-story and bulk) now stamp a durable marker on the story, and both paths
  refuse a story carrying it — or a lifecycle entry in the audit log — with a new 422
  (`story_entered_lifecycle`). Re-running force-unclaim on an already-pending story stamps it
  too, which is the remedy for a story reset before the column existed — but only while some
  evidence of the work SURVIVES (a row marker, or a `status_changed`/`auto_reset` audit row
  still inside `AUDIT_RETENTION_DAYS`). A story reset with a non-dispatch-minted key longer ago
  than that has none left: the re-run returns 200, stamps nothing (it logs
  `lifecycle_retro_stamp_skipped`), and the story stays backfillable. **Reject it** rather than
  rely on the remedy there. The row stamp is the longer-lived half deliberately: `audit_log`
  is partitioned and pruned at `AUDIT_RETENTION_DAYS` (default 90), so an audit-only guard would
  have reopened this path on a timer. **The marker is a dedicated
  `stories.lifecycle_entered_at` column** (migration `20260807153000`, which carries forward
  any marker already written AND stamps every story whose audit log still shows it was WORKED
  — `status_changed`/`auto_reset`, never `force_unclaimed`, which an operator writes on a
  never-dispatched story too — so the evidence surviving at deploy time becomes permanent
  without making the guard's expiring half permanent; its `down` copies the
  column back into `metadata` before dropping it, so a rollback does not destroy the markers):
  it first shipped inside `metadata`, which
  `PATCH /api/v1/stories/:id` replaces wholesale, so a single orchestrator-role request erased
  it and restored the launder path. The column appears in no changeset `cast`, so no request
  body can reach it; the legacy `metadata` key is still honoured on read. The column is
  returned on every story payload. Imported and never-dispatched work — the case backfill
  exists for — is unaffected.
  Backfill is additionally mounted on the LCP-1 signed-claim gate, so under the `signed` custody
  profile an enrolled caller must sign it exactly as for `verify`, and the verified claim is
  recorded in the hash-chained audit log (§9.4) as it is for `verify`.

- **The caller's dispatch lineage is now compared on every custody path, not just single-story
  verify.** `POST /epics/:id/verify-all`, `POST /stories/:id/reject` and the bulk verify/reject
  endpoints reached the same terminal states while comparing only story fields, so an
  orchestrator dispatched inside the implementer's own lineage cleared them where
  `POST /stories/:id/verify` returned `409 self_verify_blocked`. All four now resolve the
  caller's lineage server-side from the authenticating key. **What changed for clients:** calls
  that were previously accepted from ON the implementer's lineage chain (an ancestor or a
  sub-agent; siblings are fine) now return `409 self_verify_blocked` (bulk: a per-story error
  entry) — use a sibling or independently-rooted verifier dispatch. A key that no dispatch
  minted (a legacy env-var key) gets `409 caller_lineage_required` on report, review-complete
  and verify of DISPATCH-MINTED work, because its separation cannot be shown; mint an ephemeral
  key with `POST /api/v1/dispatches`. That is a plain refusal and records no custody violation,
  so it never arms a tenant halt. Stories that predate dispatches are unaffected, and `reject`
  is deliberately exempt so bad work can always be sent back.

## [Unreleased] — 2026-07-24 — Self-hosting: fresh-install fixes, multilingual search, at-rest ingestion encryption

Operator-facing changes for deployments outside the hosted instance.

### Added

- **`CLOAK_KEY` rotation is now an operable secret update (#622).** Two new variables,
  `CLOAK_KEY_TAG` (default `AES.GCM.V1`) and `CLOAK_RETIRED_KEYS` (comma-separated
  `TAG:BASE64_KEY` entries, decrypt-only), replace the compile-time retired-cipher list that
  previously made a key rotation require a code change and a redeploy. That list was also
  inert: it was configured under a `retired_ciphers:` key Cloak never reads, so following it
  would have produced undecryptable rows. **Deploy ordering matters, in TWO commands:**
  first publish the new key decrypt-only (`CLOAK_RETIRED_KEYS="NEWTAG:NEW_KEY"`), then in a
  second `fly secrets set` promote it to `CLOAK_KEY`/`CLOAK_KEY_TAG` and retire the outgoing
  key. One command would leave a rolling-restart window in which a not-yet-restarted machine
  has no cipher for the new tag; and the retired key must never land after the new active
  key. Bump the tag in the promotion command, because Cloak selects a decrypt cipher by tag
  and a reused tag hands the old key's rows to the new key. A malformed entry, a duplicate
  tag, a wrong key length, a value that is set but names no entries, or a tag colliding with
  `CLOAK_KEY_TAG` aborts boot naming the entry's position, rather than silently dropping a
  key. Full procedure, including when it is safe to unset `CLOAK_RETIRED_KEYS`:
  [`docs/runbooks/cloak-key-rotation.md`](docs/runbooks/cloak-key-rotation.md).

- **`mix loopctl.reencrypt_secrets` re-encrypts stored rows onto the active key (#622).**
  It replaces a same-named placeholder that printed a message and did nothing while the
  operational docs pointed at it as the rotation mechanism. The pass is batched, idempotent
  and resumable (it skips rows already on the active cipher), has a `--dry-run`, and a
  `status` subcommand that counts stored ciphertext by cipher tag so a rotation can be
  verified against the database rather than against the run's own summary. Every examined
  row is accounted for in the counts, and a row whose plaintext cannot be recovered is a
  reported failure with a non-zero exit — never a silent skip. Encrypted values inside
  `oban_jobs.args` are NOT covered and the `status` census cannot see them; draining BOTH
  the `:ingestion` and `:cleanup` queues is what retires those before the old key is
  dropped.

### Changed

- **Webhook deliveries now carry a timestamped signature; receivers must migrate (#623).**
  Every delivery gains an `X-Webhook-Signature` header in the form
  `t=<unix_seconds>,v1=<hmac_sha256>`, where the MAC covers `"<t>.<raw_body>"` rather than the
  body alone. Because the timestamp is inside the MAC, a receiver can bound how long a given
  signature is worth honouring instead of accepting any `(body, signature)` pair indefinitely.
  **Recommended receiver behaviour:** recompute the MAC over the raw bytes you received (not a
  re-encoded parse), compare in constant time, reject when `|now - t|` exceeds **300 seconds**,
  and keep a short-lived cache of `X-Webhook-Id` covering at least that window — loopctl retries
  a delivery under the SAME id, so cache on "already processed successfully", not "already
  seen". `README.md` carries a worked example.
  **Migration:** the legacy `X-Signature-256` header (`sha256=<hmac(raw_body)>`) is STILL SENT
  unchanged for a deprecation window, so no receiver breaks today; it will be removed. Nothing
  to configure — signing secrets are unchanged.

- **A webhook delivery failure no longer records the destination's response body.** The stored
  delivery error, which a tenant reads back through the deliveries API, previously included the
  first 200 characters of whatever the destination returned. It now carries the status code and
  the response `content-type` only, so a delivery record describes the failure without carrying
  back content from wherever loopctl was pointed. Debugging a receiver you own is unaffected:
  status and content-type identify the failure, and the receiver's own logs hold the rest.

- **`LOCAL_ENDPOINT_ALLOWLIST` entries are now purpose- and port-scoped (breaking for some
  deployments).** An entry is `host[:port][@purpose[+purpose...]]` or `cidr[@purpose...]`, where
  purpose is `inference`, `webhook` or `ingest`. **An unqualified entry grants `inference`
  only.** Previously one entry granted every purpose on every port, so a carve-out made so the
  deployment could reach its own model endpoint also made those hosts legal destinations for
  tenant-authored webhook deliveries and tenant-authored ingest fetches, and a
  `host:port` entry silently granted every port on that host.
  **Action required** if you rely on an allowlisted host for webhook delivery or content
  ingestion: name the purpose — `10.0.0.5@webhook`, `ollama.internal@inference+ingest`. Local
  model endpoints (the common case) need no change. A port written in an entry now binds it to
  that port; an entry with no port still matches any port — every port on that host, and for
  `webhook`/`ingest` the destination port is tenant-chosen, so state the port on any entry that
  exists for a single service. Existing bare-host entries keep working. An IPv6 literal must be
  bracketed when it carries a port (`[fdaa::1]:8080`) and bare when it does not (`fdaa::1`). An entry naming an unknown purpose grants nothing and is reported by `egress_posture`
  at `:user`+ (and logged) as a defect rather than dropped silently.
- **BREAKING (API): `idempotency_key` is no longer returned in any article payload.** It is
  still accepted on create and still a filter on `GET /api/v1/articles?idempotency_key=…`
  (and the `knowledge_list` / `knowledge_count` MCP tools) — the lag-free existence check
  is unchanged, answered from `meta.total_count` on a key you already hold. What it no
  longer does is hand every reader the capture identities of articles it merely has read
  access to. A key is caller-chosen data that the nightly consolidation pass reads when it
  groups duplicate captures, so it is write-side identity, not a shared attribute. The
  same removal applies to the `evidence` entries of `GET /api/v1/knowledge/consolidation`,
  prior-day reports included. The create no-op response still echoes the key you SUPPLIED on
  an idempotency hit; nothing else does. A client reading the field off a list/get response
  must switch to filtering by the key it already holds. The filter is not scoped to keys you
  wrote, so this removes a bulk disclosure — it does not make the key a secret.

- **A `supersede` verdict's `confidence` is now granted by the server, not accepted
  from the request** (`POST /api/v1/knowledge/conflicts/resolve`). `confidence: "high"` on a
  `supersede` is what authorizes the nightly executor to RETIRE an article with nobody in
  the loop, so it is now capped by the role of the key recording the verdict: an agent-role
  request asking for `"high"` is recorded at `"medium"`, and the response reports the cap in
  `data.requested_confidence` and `note`. `merge` is NOT capped — it synthesizes a new draft
  and retires nothing — so it still executes at agent role. Recording a verdict remains
  agent-role curation in every disposition; only the unattended retirement is gated.
  **Both `supersede` AND `merge` recorded at `"high"` now REQUIRE `evidence` (422 without
  it)** — the merge is uncapped but not free: the executor synthesizes on the tenant's own
  paid model key and POSTs both article bodies to the provider, so every verdict it applies
  unattended must carry its reason. A merged draft now also inherits the more restrictive of
  its two sources' visibility instead of defaulting to tenant-shared, and two sources
  restricted to DIFFERENT agents are refused before any synthesis.
  **A capped verdict is neither applied nor auto-dismissed:** a pair whose only verdict the
  executor will never apply stays listed in `GET /api/v1/knowledge/conflicts` (and keeps its
  link on `GET /articles/:id`), so an orchestrator+ key can find it and re-record it. A
  supersede/merge DELIBERATELY recorded below `"high"` is different — the next nightly run
  closes it as dismissed (both articles retained) and the pair leaves the queue; it is not
  held for review, so re-record at `"high"` if you mean it to apply. An execution that
  disposed of NOTHING (a merge skipped for a missing API key, a permanently failed
  synthesis, a retracted flag) no longer settles the pair either — it stays discoverable
  instead of vanishing unapplied. Recording ANY verdict, capped or not, releases the pair's
  articles from curated-retrieval suppression. The
  migration backfills `annotated_by_role` from the existing `annotated_by` value, so a
  pending `supersede` an orchestrator recorded before this release still executes.

- **The nightly consolidation pass now keeps the OLDEST member of a duplicate group, not the
  longest.** Both signals that form a group — the normalized title and the
  `idempotency_key` — are caller-chosen, and so is the body, so under longest-wins an agent
  could retire an established published article by publishing a longer near-copy beside it.
  Age is the one input a later writer cannot manufacture. **Operator impact:** where a
  fuller re-capture used to win, the earlier capture now survives and the fuller one is
  unpublished (reversible via publish; its text is retained as a draft).

- **The nightly consolidation pass now requires content corroboration before auto-
  unpublishing an idempotency-key duplicate group,** as it already did for title-collision
  groups. An `idempotency_key` is caller-supplied, so two unrelated writers can collide on
  one deterministically and the two-run agreement gate — which filters transience, not
  wrongness — would confirm it. Both signals now clear the same bar: the group's live
  members must also be similar in CONTENT (`knowledge_consolidation_min_duplicate_similarity_pct`).
  **Operator impact:** a tenant with no BYO embedding key can no longer auto-apply
  idempotency-drift groups — they are REPORTED and withheld instead (nothing is
  unpublished), and the withhold clears itself once vectors exist. This is the behaviour
  title-drift groups have always had on such tenants.
- **A custody halt now requires a repeated pattern, and it no longer freezes the whole API.**
  Two behaviour changes an operator will notice.

  **When a halt fires.** Previously a SINGLE chain-of-custody refusal halted the tenant, and
  clearing a halt requires a human WebAuthn break-glass ceremony. A halt now requires
  **3 self-report / self-review / self-verify violations within 1 hour** (tunable with
  `config :loopctl, :custody_halt_threshold` and `:custody_halt_window_seconds`; a value that
  is not a positive integer is refused back to the default with a warning, since `0` would
  halt on the first violation and a string from an env var would halt nobody, ever); below the
  threshold the offending operation is refused exactly as before, with the same 409 — only the
  escalation changed. The `self_review_blocked` 409 body now carries `code` and
  `remediation.learn_more` like its two sibling gates, so all three are machine-dispatchable. Capability-token rejections no longer contribute to a halt at all: a
  capability is single-use with a bounded TTL, so a plain client retry, a resumed agent or an
  audit-key rotation all produce one, and none of those is evidence of anything. They are now
  reported as `[:loopctl, :custody, :cap_rejected]` telemetry plus a warning log — **alert on
  the rate**, not on single events. Halts themselves emit `[:loopctl, :custody, :halt]`
  telemetry and a `custody_halted` **error** log carrying the tenant, the reason and the count,
  so a halt reaches your alerting immediately; each halt is also recorded in the hash-chained
  audit log. Violations are retained in a new `custody_violations` table (tenant-scoped, RLS)
  as the forensic record behind a halt. New migrations, no manual steps.

  **What a halt blocks.** A halt used to 503 EVERY authenticated request for the tenant,
  including all reads. It now suspends only the custody surface: story-lifecycle writes,
  bulk story operations and epic verify-all, dispatch minting, and agent-memory writes.
  Reads are never blocked on any surface, and knowledge-wiki and coordination writes keep
  working — a halted tenant retains the audit log, change feed and KB access needed to
  investigate the halt. Root-of-trust rotation (`POST /tenants/me/custody-owner-key`,
  `POST /tenants/:id/rotate-audit-key`) also stays reachable, since it is a remediation path.
  The 503 body now carries `scope: "custody_operations_only"` so a client can tell a scoped
  halt from an outage. If you have monitoring that treats any 503 `tenant_halted` as
  "tenant is down", it will now see the halt only on custody calls.

- **`POST /tenants/me/custody-owner-key` is rate limited per tenant (#624).** Registering or
  rotating the custody owner key now shares the shape of the WebAuthn enrollment ceremony's
  limiter: an hourly per-tenant budget that **fails closed** — if the rate-limiter store is
  unavailable the request is refused with `429 rate_limited` rather than allowed through.
  Rotation was, and remains, additionally gated by proof of possession of the outgoing owner
  key; this is defence in depth for an expensive verification path.

- **Ingestion now mints self-qualifying article titles (#617).** The extractor was shown only
  a coarse `source_type` ("web_article"), never which document it was reading — so a CHANGELOG
  file could only be titled "Changelog". On the hosted corpus three unrelated documents (a
  WordPress SEO plugin, the Elixir oauth2 library, a WordPress theme) each produced exactly
  that, and the nightly consolidation pass then proposed them for auto-unpublish as "the same
  capture". The specific source is now passed to the extractor, and the prompt asks for a
  title that stands alone in a shared corpus — qualified by its source when the natural title
  is generic ("Changelog — Platinum SEO Pack WordPress plugin"), left alone when it is already
  specific. **What this sends:** for a URL ingest the scheme+host+path of the ingest URL is
  included in the extraction prompt POSTed to your configured LLM provider; userinfo and the
  query string are stripped first, so credentials and query-string signatures are not
  transmitted — the host and PATH are, so a share link that carries its token in a path
  segment (`/s/<token>/file.pdf`, `/document/d/<id>/edit`) still sends it. Name the source
  explicitly with `metadata.source_ref` (an inline `content` ingest has no other way to be
  named, and it OVERRIDES the URL-derived name, which matters when a URL's identity lives in
  its stripped query string); it is reduced exactly the same way. Without it the source line
  is omitted entirely, never sent as a placeholder. This affects NEWLY ingested content only; existing articles are untouched. It
  is the root cause behind the duplicate-capture class the previous entries bound and gate.

- **The consolidation drain caps AND the duplicate-similarity threshold are now live-tunable
  without a deploy (#617).** `knowledge_consolidation_max_applies`,
  `knowledge_consolidation_max_unpublishes`, `knowledge_consolidation_max_per_class` and
  `knowledge_consolidation_min_duplicate_similarity_pct` (an INTEGER percent — `80` means
  0.80 — which is the threshold a title collision's members must corroborate at in content
  before the nightly may unpublish one; only **1..99** is accepted, because `0` on this knob
  would satisfy the corroboration check for every pair rather than disabling it, and any
  other value falls back to the config layer) are read from `SystemConfig` DB rows first,
  falling back to the compile-time application config and then to the built-in default. The
  drain caps still read `0` as "halt", which this threshold deliberately does not. Setting
  `knowledge_consolidation_max_unpublishes` to **0** halts the auto-unpublish drain, and that
  halt now takes effect on the next nightly rather than on the next deploy — which is the
  whole point, since the caps are the only lever an operator has while an apply is going
  wrong. The existing config values keep working unchanged; nothing needs to be set.

- **An over-long input no longer permanently strands a row un-embedded (#617).** #615 added
  the byte budget and shrink ladder to the two article-embedding workers. The same rejection
  on the re-embed, system-corpus, agent-memory and novelty-gate paths still mapped to a
  permanent 4xx and DISCARDED the job — so a single over-long article could wedge a whole
  tenant re-embed mid-run (leaving recall pinned at the old dimension), and an over-long
  memory was permanently absent from semantic recall. All four now walk the same ladder,
  embedding a prefix rather than nothing. Array calls bisect first, so only the member that
  actually overflows is truncated. No configuration change; the effect is fewer rows silently
  missing from semantic search. A vector that covers only a prefix is MARKED where it is
  stored, and the three readers that compare vectors treat it accordingly: the novelty gate
  will not call a proposal a duplicate on one, the nightly will not corroborate a title
  collision on one, and agent-memory promotion will not retire a memory on one.

- **The nightly re-checks that a confirmed duplicate group still COLLIDES before unpublishing
  it (#617).** The apply path previously re-checked only that the group's members were still
  published. Retitling the articles is the remedy for a false grouping, and a retitled group
  passed that check — it was saved only because a fresh derivation happened to drop the group
  first. The grouping signal (normalized title, or normalized idempotency key, whichever
  formed the group) is now re-evaluated at apply time; a group that no longer collides as one
  whole — dissolved, split, or any live member dropped — is skipped and re-derived. The same
  holds when the group is SHRUNK rather than split: if a confirmed member was archived,
  deleted or made private, the survivors are a set no report ever confirmed and the pass
  skips them (its own part-drain, which leaves the member a shared draft, still converges). A
  duplicate group also carries at most 50 members onto one proposal. The remainder is
  re-derived on the next run and applies the run AFTER that: the survivors are a different id
  set, so their fingerprint has to appear in two consecutive reports before the agreement gate
  will confirm it. A very large group therefore drains 50 members every two nights.

- **The nightly consolidation drain rates are raised so the duplicate backlog converges to
  zero instead of to a floor (#611).** Three settings, all previously pinned to module
  defaults sized for a class that had never applied anything in production:
  `knowledge_consolidation_max_per_class` (100 → **500**, the existing hard ceiling),
  `knowledge_consolidation_max_applies` (**new**, default 500) and
  `knowledge_consolidation_max_unpublishes` (**new**, default 500).

  The per-class cap is the one that mattered. Auto-apply requires a proposal in **both** of
  the last two reports, so a standing backlog larger than the report cap could never drain
  however long the pass ran — the hosted corpus sat at 290 proposals with 100 visible, a
  queue converging to a floor rather than to zero. The two apply caps were additionally
  UNREACHABLE: `apply_confirmed_duplicates/2` accepted them as options and the worker passed
  none, so operator configuration had no effect and draining a backlog required calling the
  context directly.

  The bounds themselves stay — a bug that mis-picks winners must be visible after one night
  rather than after the whole corpus — and unpublish being reversible by publishing is what
  licenses a bound this size. Evidence for the new sizing: on 2026-08-06 (UTC) the class unpublished
  112 loser articles on the hosted corpus, and **all 112 were verified to still have a
  surviving published twin**, with zero private articles touched.

  Both apply caps are clamped to **0..500**: 500 is a hard ceiling, so raising a value above
  it has no effect, and a non-integer value is ignored in favour of the built-in default.
  Setting either to **0 pauses the auto-unpublish drain** — nothing is applied and the audit
  event records `duplicate_apply_gate=drain_disabled`, so a paused night is distinguishable
  from a clean one. That is the supported way to halt the drain during an incident. A
  duplicate group with more losers than the cap is now drained as far as the cap allows
  (the surviving winner is never touched) instead of being skipped whole, which had made any
  group larger than the cap permanently unappliable.

- **The nightly knowledge pass now PRUNES the `relates_to` graph to a bounded degree, which
  DELETES rows (#611 stage 0).** Read this before upgrading if you run a large corpus: on
  first run the pass will delete a large number of `article_links` rows, and it is the only
  step in that worker that deletes anything.

  Why: a similarity threshold was never a bound. Above `article_link_threshold` (0.6) the
  linking worker created a `relates_to` edge for *every* kNN candidate — up to
  `article_link_max_comparisons` (50) outbound per article, plus one inbound from every other
  article that reached it. On the hosted corpus that produced **1,402,699 edges over 79,276
  published articles**, with 56% of articles carrying 21+ and 59% of edges sitting between
  0.60 and 0.70. At that density a traversal from any article reaches most of the corpus in
  two hops, so the graph asserts a relationship between nearly everything and distinguishes
  nothing — which also means the one-hop enrichment in progressive disclosure was spending
  its budget on noise.

  What changes: `ArticleLinkingWorker` now writes `relates_to` edges only up to
  `article_max_relates_to_links` (**new setting, default 10**) minus the prunable edges an
  article already holds — a re-link tops it up to that number rather than adding that many
  more. That bounds what the worker writes for the article it is linking; edges other articles
  write INTO it are bounded by the prune below, not by this setting.
  `Loopctl.Knowledge.LinkPruning` drains
  the existing backlog at up to `knowledge_link_prune_max_per_run` (**new setting, default
  250,000**) edges per nightly run, worst-first, reporting the remainder on the
  `knowledge.lint_completed` audit event as `links_pruned` / `links_prunable_remaining`.
  On the hosted corpus the target state is 499,058 edges (~12.6 average degree).

  What is NOT touched: `potential_conflict` edges (own threshold, own draining consumer),
  any `relates_to` link without `auto_generated: true`, any link without a recorded
  `similarity_score`, and any `relates_to` edge at or above `knowledge_conflict_threshold`
  whose pair the conflict promoter has not flagged yet (those rows are the promoter's only
  input, and it drains them far slower than the prune would delete them; once a pair is
  flagged it is no longer promoter input and the edge is prunable like any other). A hand-made
  link is structurally out of reach, and an edge that cannot be ranked cannot be shown to be
  prunable.

  Why deleting is safe unattended, when every other automated step in that worker is gated on
  reversibility: an auto-generated edge is a *derived artifact*, not a record — a pure
  function of two embeddings and a threshold, which the linking worker recomputes from the
  same vectors. Pruning uses **union-kNN** (an edge survives if it is in *either* endpoint's
  top-K), which guarantees every article keeps its own K nearest and therefore **cannot create
  an orphan**. No migration, no manual step; the pass is idempotent and converges.

### Added

- **`GET /api/v1/knowledge/consolidation` — the nightly consolidation ("dream") report
  (#584, #605, #606, #608).** The existing nightly knowledge pass (04:00 UTC,
  `KnowledgeLintWorker`) now also reconciles the tenant's published corpus and emits numbered
  proposals, each naming the articles involved and quoting an excerpt from each as evidence:
  duplicate captures from title/idempotency-tag format drift, and placeholder titles.
  **Operators should know the pass now writes to `articles`, in exactly one way:** it
  UNPUBLISHES the losers of each duplicate group that two consecutive nightly reports both
  propose (bounded at 25 groups per run, winner recomputed at apply time against the live
  corpus). It is an unpublish and never an archive — `archived` is terminal for an article,
  so an unattended pass may not take that one-way door, while unpublish is undone by
  publishing. Nothing else is written: no `article_links`, no `conflict_resolutions`. There
  is no approve/reject surface and there will not be one; `review_status` persists but
  decides nothing. Two proposal classes were retired before ever reaching a release:
  `contradiction_candidate` (the same nightly run's lint judges those pairs itself, so
  consolidation was reporting a pile another writer already drains) and `stale_entry` (age is
  not a defect signal — use `GET /api/v1/knowledge/lint`, which computes staleness with a
  caller-chosen `stale_days`). Both values still load from stored rows and are still accepted
  by the `class` filter. Deliberately NOT a second scheduler: it runs inside the existing
  nightly job, so there is still one pass per tenant over the corpus. Migration
  `20260805140000_create_consolidation_reports.exs` adds `consolidation_reports` and
  `consolidation_proposals` (both RLS-enabled, tenant-scoped, cascading on tenant delete); no
  manual step. Note for operators: proposal rows persist a 240-character excerpt of each
  cited article body alongside the article ids, so the report inherits the sensitivity of the
  articles it cites — it is tenant-scoped and orchestrator-gated like every other knowledge
  read. That inheritance does NOT outlive the article: evidence is re-checked against the live
  corpus on every read, and an entry whose article has since been hard-deleted or
  archived comes back redacted (title null, empty excerpt, `redacted: true`),
  including in prior-day reports read via `?day=`. A draft is still live — the pass's own
  unpublish must not blank the evidence for the action it took. The response `meta` carries NO `applied`
  flag: a report records what was PROPOSED, and the apply tally rides the worker's
  `knowledge.lint_completed` audit event as `consolidation.duplicates_unpublished` /
  `consolidation.duplicate_groups_skipped` / `consolidation.duplicates_unpublish_failed`
  (plus `consolidation.apply_error` when the apply could not run at all) — the failure keys
  are what separate a night where every write was rejected from a night with nothing to apply. Per-class proposal cap is configurable via `:knowledge_consolidation_max_per_class`
  (default 100, hard max 500); over-cap is logged with the true total, never silently dropped.

### Changed

- **BREAKING (tags): the `idem-` tag prefix is now RESERVED for per-source idempotency keys
  (#583).** A tag starting with `idem-` must be `idem-<family>-<digest>` where `<digest>` is a
  12- or 40-character lowercase hex digest (e.g. `idem-url-7ebe1ca33431`); both digest lengths
  are accepted because the harvest sourcers' suffix used to be a full sha1 and is now
  truncated. Anything else claiming the prefix — `idem-design`, `idem-url-notahex` — is now
  rejected `422` on `POST /api/v1/articles` and `PATCH /api/v1/articles/:id`, and by the
  changeset underneath every other writer, so nothing is ever silently re-prefixed and a
  caller always knows what was stored. **The MACHINE paths drop the tag instead of failing**, on
  purpose: OKF import drops a foreign tag that sanitizes into the reserved namespace (the
  original string is preserved under `metadata["okf"]["tags"]`, and a well-formed reserved tag
  that arrives unchanged — every loopctl-native bundle — round-trips intact), the review worker
  and the content-ingestion worker strip a malformed reserved tag out of extractor output before
  insert (all of a review's extracted articles share one transaction, and an ingested article
  whose changeset is invalid is dropped whole, body included), and memory graduation filters one
  out of a memory's tags so a hot memory can never burn its one-shot graduation on an article
  that fails to insert. Script against a `422` only on the two
  API endpoints. Topical tags outside the prefix are unaffected, and the bare pre-reservation
  form (`url-<hex>`) is still accepted so existing sourcers keep working. For
  server-guaranteed idempotency prefer the `idempotency_key` field, which has a per-tenant
  unique index — a tag is caller-controlled data.
- **Manual step (optional, operator-run): `mix loopctl.reserve_idempotency_tags` (#583).**
  Promotes pre-reservation `<family>-<digest>` tags to their reserved counterpart across the
  corpus. Dry-run by default; `--apply` writes, `--tenant <uuid>` restricts scope. The first
  pass ADDS `idem-url-<hex>` alongside the existing `url-<hex>` so current dedup reads keep
  working; run it again with `--drop-legacy` to remove the bare form only after every client
  has switched to the reserved tag. Re-running is a no-op — a tag is never double-prefixed.
  Promotion requires BOTH halves of the shape: a known source family (`url`, `doc`, `book`,
  `yt`, `repo`, `img`, `file`, `vid`, `web`) AND a 12- or 40-char lowercase hex digest. So
  `url-design` is left alone (no digest), and so is `commit-<sha>` or `release-202604150930`
  (not a source family) — an unknown family is never promoted, because promoting it would
  fabricate a capture identity and `--drop-legacy` would then delete the original tag. An
  unrecognised switch aborts the run rather than being ignored.
- **`GET /api/v1/knowledge/analytics/retrieval-metrics` gained four fields and a stated
  denominator (#582).** `precision` and its `searched` denominator are UNCHANGED — `searched`
  has always counted RECORDED SURFACED RESULTS (one `article_access_events` row per result a
  search put in front of an agent, capped at the first 20 results of each call), so
  `precision` has always been "the share of the recorded surfaced results that were opened",
  i.e. precision@20: a call returning more results contributes only 20 to `searched`, and an
  open of a result ranked beyond the cap appears in neither term. What changed is that the
  payload now says so and reports the per-CALL quantity separately, because the field name
  reads like a count of searches and was consumed that way. New fields: `results_recorded`
  (same number as `searched`, named for its unit), `searches`, `searches_with_follow_through`,
  `search_follow_through` (the share of QUERY-BEARING search CALLS that led to an open), and
  `results_returned` (the true un-truncated result count for those same calls, so it exceeds
  the rows those calls wrote whenever a page hit that cap). The four call-level fields are filtered per ROW, not per day: a row counts
  only if it carries a search identity (nothing recorded before this release does) and is not
  a query-less enumeration page (`list` / `list_keyset`, written by the browse endpoints —
  browsing is not searching). So a day that MIXES qualifying and non-qualifying rows reports a
  PARTIAL figure rather than `0`, and `results_returned` must NOT be compared against
  `searched`: they aggregate different row populations. Migration
  `20260805130000_add_call_level_columns_to_retrieval_metric_snapshots.exs` adds the four
  backing columns with `default 0`; no manual step, and no backfill is possible — snapshots
  recorded before this release read `0` because their source events carry no search identity.
  Both ratios are UPPER BOUNDS: zero-result and keyless searches cannot be recorded and sit in
  no denominator; and both rise if a search simply returns fewer results, so pair them with
  the absolute `followed_through` rather than optimising either alone. `search_follow_through`
  carries two further biases pointing OPPOSITE ways: the 20-row recording cap hides opens of
  results ranked beyond it (biases it DOWN on large pages), while one open credits EVERY
  search in the window that surfaced that article, not just the preceding one (biases it UP
  when an agent refines and re-searches).

- **The legacy `articles_embedding_hnsw_idx` is retired on installs whose reads are cut over
  to the embedding side table, and reverting `embedding_side_table_reads` to `0` there is now
  an UNINDEXED read path (#578).** Measured on the hosted instance 2026-08-04
  (`pg_stat_user_indexes` / `pg_stat_statements`): the legacy index held 657 MB for 26 scans
  while the live `article_embeddings_hnsw_dim_1536_idx` held 658 MB for 1,695 — and with
  `shared_buffers` at 1536 MB the two evicted each other, so a cold vector search took
  8,044 ms of which 7,926 ms (98.5%) was `blk_read_time` against 0 ms warm. Dropping the
  legacy index frees roughly that 657 MB and leaves the live index resident.
  `migrations/20260805120000_drop_legacy_articles_embedding_hnsw_index.exs` performs the drop
  **only when `system_configs.embedding_side_table_reads` is `1`**; the flag defaults to `0`
  (= the legacy `articles.embedding` column) and no migration seeds it, so a fresh install and
  any install that has not cut over KEEP the index and are unaffected. **On a cut-over
  install** you may run `DROP INDEX CONCURRENTLY articles_embedding_hnsw_idx` out-of-band
  ahead of the deploy if you want the space back without waiting on the migrator — `IF EXISTS`
  makes the migration a no-op afterwards. Do NOT run that by hand on an install that has not
  cut over: it destroys the index serving your live read path, and the migration only ever
  drops, so it cannot give it back. **Operator consequence:** on an install where the drop has
  run, setting the flag back to `0` puts every semantic read on an unindexed column (seq scan +
  top-N sort). That trips the heavy-read `statement_timeout`, and the cancel surfaces as a hard
  `504`/`db_statement_timeout` — NOT `503`/`heavy_read_overloaded`, which only the per-tenant
  concurrency shed produces, and NOT the labelled keyword fall-back, which matches that shed
  alone. There is no graceful degrade on this path today: semantic search returns no results.
  Rebuild the index FIRST with an explicit
  `CREATE INDEX CONCURRENTLY articles_embedding_hnsw_idx ON articles USING hnsw (embedding vector_cosine_ops)`
  plus the same `WITH (m, ef_construction)` the migration builds with, and raise
  `maintenance_work_mem` well above the 64 MB default or the ~657 MB HNSW build silently falls
  back to the slow on-disk path.
  `mix loopctl.embeddings revert` now REFUSES while that index is absent (detected by
  capability, not by name) and prints the rebuild above; `mix loopctl.embeddings revert
  --force` overrides the refusal, and `mix loopctl.embeddings status` reports the index as
  `legacy articles.embedding HNSW index:`. **That refusal only protects installs that run
  from source** — a release ships no `mix`, so if you revert with `bin/loopctl eval` or a
  `psql` UPDATE, nothing checks the index for you and the rebuild-first ordering below is
  the only guard. The retirement procedure — the out-of-band drop,
  the baseline above as a fixed point, and the `pg_stat_statements` query that takes the
  matching AFTER reading — is `docs/runbooks/embedding-dimension-cutover.md` (Retiring the
  legacy articles ANN index); the revert procedure is the Reverting section of the same file. A rollback rebuilds it too —
  `bin/loopctl eval "Loopctl.Release.rollback(20260805120000)"` (there is no `mix` in a
  release) — but Ecto's `:to` is INCLUSIVE, so that reverts every migration at or after that
  version; once anything newer has shipped, use the explicit `CREATE INDEX`. If you do roll
  back, flip `embedding_side_table_reads` to `0` BEFORE the next
  `bin/loopctl eval "Loopctl.Release.migrate()"`: the rollback makes the migration PENDING
  again, and a deploy in that gap re-runs it and re-drops the index you just rebuilt. The
  `articles.embedding` **column is unchanged**: still dual-written, still the
  backfill/reconciliation source. `memories` keeps both of its legacy-column indexes
  (deliberate — one serves `include_superseded: true` recall, the other default live recall).
  No new environment variables.

- **`loopctl.oban.poll.error.count` label values changed — re-point any Prometheus selector
  or Grafana panel (#558).** The `error_class` label moved from a bare `exit` / `throw` to the
  kind-prefixed, closed set produced by `Loopctl.ExitClass` — `exit:noproc`, `exit:timeout`,
  `exit:Postgrex.Error`, `throw:other`, and so on. A selector matching the old bare values
  **silently stops firing** rather than erroring, which is the worst failure mode an alert
  has. The same vocabulary is now shared by the ingestion backlog-gate and vector-search
  under-fill counters, so one query shape works across all three.

- **`loopctl.ingestion.backlog_gate.failed_open.*` gained an `:outcome` label, and a `jobs`
  sum alongside the counter.** The event now fires on refusals as well as admissions, so a
  dashboard reading the counter alone over-reports admissions during exactly the sustained
  incident it is alerted on; slice by `outcome` (`admitted` / `unmetered` / `exhausted`). The
  `jobs` series is job-denominated — one 50-item batch is one check but fifty jobs.

- **A DB pool fault that arrives as an EXIT now renders the pinned 503/504 instead of a bare
  500, and counts in `loopctl.db.error.count`.** Crash propagation from a pooled process is an
  exit, not a raise, so it previously escaped the endpoint backstop untranslated: no
  structured SQLSTATE line, no counter increment (the aggregate under-counted DB faults during
  exactly the pool wedge it is read in), and the raw reason — the failing statement plus the
  call's bound parameters — reached the web-server crash log. Exits the backstop cannot place
  in the pool are still re-exited untouched.

- **The ingestion fail-open allowance is metered on the node-local limiter even under
  `RATE_LIMITER=postgres`.** The Postgres limiter store is `AdminRepo` — the same pool whose
  exhaustion makes the backlog unmeasurable — so the allowance was unconsultable for exactly
  the fault it bounds and admission stayed unbounded during a sustained wedge. Every other
  limiter bucket still follows `RATE_LIMITER`.

- **`POST /knowledge/ingest[/batch]` can now answer `503 ingestion_gate_unavailable` where it
  previously answered `429 ingestion_backlog_exceeded`.** Only for the refusals that are NOT
  backlog pressure: the gate could not MEASURE the backlog because of a driver/config fault or
  a defect in the counting code, and the bounded allowance for admitting unmeasured work is
  spent. The 429 asserted a backlog nobody counted and advised waiting for a drain that a
  deterministic fault never reaches. `Retry-After` is set on both; a client branching on
  `error.code` needs no change, one branching on the status does.

- **Tightening `OBAN_INGEST_BACKLOG_MAX` now tightens the ingest fail-open allowance with it
  (#564).** That allowance — how many jobs a tenant may have admitted while the gate cannot
  MEASURE its backlog — is `max(1, OBAN_INGEST_BACKLOG_MAX / 10)` per web node, sized so a
  10-node fleet stays at or under one threshold per hour. A floor at one full batch (50)
  previously took over for any threshold below 500, so lowering the knob to e.g. `100` left
  the allowance pinned at 50/node — a fleet admitting 500/hour against a threshold of 100,
  silently, and in the direction an operator assumes is the safer one. Effect at the default
  of 500 is unchanged. Below a threshold of 10 the allowance floors at 1 rather than 0, so a
  transient blip cannot refuse EVERY request — but a request asking for more items than one
  window's allowance still cannot fit it, and is refused after a single token rather than
  burning the remainder on jobs it will not enqueue. `OBAN_INGEST_BACKLOG_MAX` and
  `OBAN_INGEST_BACKLOG_RETRY_AFTER` are now documented in `deploy/FLY_SECRETS.md`, where
  they should have been all along.

- **`POST /knowledge/ingest[/batch]` can answer `503 ingestion_gate_unavailable` for a
  `db_error` too (#564).** It was the last unmeasurable-count class still admitting
  UNCONDITIONALLY — on the reasoning that a broken count query is our defect, not the
  tenant's backlog. That is a correct argument about the error CODE (and is kept: the refusal
  is the 503, never a backlog 429) but it left the class unbounded, and a deterministic
  query-shape fault recurs on every request — so the backpressure valve was simply OFF for as
  long as the bug existed. Every class is now metered. Operator-visible as ingest requests
  that previously succeeded during a counting-code fault now being refused once the hourly
  allowance is spent; the `loopctl.ingestion.backlog_gate.failed_open.*` series with
  `error_class="db_error"` is the signal to fix the query.

- **Which ingest fail-open refusals carry `429` vs `503` changed again, and the `Retry-After`
  on them is now window-scaled but capped (#565, #566).** `429 ingestion_backlog_exceeded` is
  now reserved for a fault that is demonstrable pool pressure: the SQLSTATE/exception classes
  `connection`, `timeout`, `db_pressure`, `guc_capture_abort`, plus any EXIT the driver's own
  pool raised. Pool-ness of an exit is decided from the raw exit reason
  (`ExitClass.pool_exit?/1`), not from its metric label, so a foreign `{:timeout, {GenServer,
  :call, _}}` escaping the counter takes the `503 ingestion_gate_unavailable` while a
  `{:noproc, {DBConnection, :execute, []}}` keeps the 429 — the label alone cannot tell them
  apart. A `throw:*` and every exit the gate cannot place at the pool answer the 503, like
  `db_error` and `driver_fault` already did, because none of them is evidence that the refused
  tenant has a backlog. In the other direction, the CONTENTION SQLSTATEs (40001, 40P01
  deadlock_detected, 55P03 lock_not_available) now classify as `db_pressure` rather than
  `db_error`, so heavy `oban_jobs` churn reads as load on the dashboard instead of as a defect
  in the counting query; the rest of classes 40 and 55 (55P02 cant_change_runtime_param and
  friends) stay `db_error`, since a deterministic config fault never drains. The `Retry-After`
  on an allowance-exhausted refusal now advises the time left in the hourly allowance window
  instead of `OBAN_INGEST_BACKLOG_RETRY_AFTER` (~60s) — which had a compliant client re-running
  the backlog count ~60 times per window against the pool the gate is protecting — capped at 5x
  that variable so a cleared blip cannot stall a client for a whole window. The fail-open
  allowance is also now metered in two per-tenant lanes (pressure vs non-pressure), so a
  counting-code defect can no longer spend the tokens a genuine pool fault is then refused on.
  The lanes SPLIT one threshold's worth rather than each getting one — the per-lane allowance
  is `max(1, OBAN_INGEST_BACKLOG_MAX / 20)` per web node (10 nodes x 2 lanes), so the total a
  tenant can have admitted while unmeasured stays at one `OBAN_INGEST_BACKLOG_MAX` per hour and
  there is **no multiplier to apply on top**. At the default of 500 the per-lane allowance is
  25/node.

- **New `article_access_events.access_type` value: `drill` (#569).** `GET
  /api/v1/knowledge/progressive/:id` records `drill` instead of `get`, at EVERY scope — the
  canonical carve-out this entry originally described was reversed by #572 below before
  release, so no drill records `get`. No request
  parameter is involved — the server derives it from the read path, so every client is
  covered. Operator-visible in
  two places. **Analytics filters on `access_type=get` will stop seeing those reads** —
  `GET /api/v1/knowledge/analytics/*` and anything grouping by access type must add `drill` to
  keep the same population. And the value set that column can hold has grown, though there is
  no DB CHECK to migrate: the allowlists are `ArticleAccessEvent.@access_types` and
  `Analytics.@valid_access_types`.

  Why: `heat_index` ranks on `get`, and the drill tool its own `meta.drill` payload tells
  callers to use recorded a `get` — so an article gained heat from having been *shown* by the
  index. Visibility produced reads, reads produced rank, rank produced visibility, and
  material that never surfaced could not overtake material that already had. #572 gave the
  canon a `knowledge_get` read path instead of exempting its drill, so no scope is exempt.
  Retrieval
  follow-through (`RetrievalMetrics`) deliberately DOES count `drill`, so precision figures
  are unaffected by the split.

  Nothing is back-filled: reads taken before this deploy are `get` rows and keep feeding heat
  until they age out of the window (90 days by default, up to 365 with `since`), so heat
  rankings stay partly loop-contaminated for one window after the upgrade.

- **`GET /api/v1/knowledge/heat_index` ranks by DISTINCT READERS, not by read count (#567).**
  Heat was `count(*)` over access-event rows, so any agent could pin its own article at rank 1 by
  calling `knowledge_get` on it in a loop — and because this index is meant to be pasted into a
  cached prefix, that ranking then propagated into every other agent's context. A signal the
  ranked party controls is not a signal. A reader is `coalesce(agent_id, api_key_id)` of the key
  that read — NOT the key row, since v2 mints a fresh ephemeral key per dispatch and counting
  keys would count dispatches — so one agent now contributes at most 1 however many times, and
  from however many dispatches, it reads; ties break on distinct read DAYS before the article id
  does, never on raw read count — that counter is the one a loop inflates.
  Existing `heat` values will DROP (they become readership size, not traffic) and the
  ordering will change wherever traffic and readership disagreed. Two further contract fixes on
  the same route: `meta.heat_window`'s system-derived bounds sit at the start of today
  (an explicit `since` is served verbatim, per #572 below), so two calls with no intervening
  read return a byte-identical payload (it previously carried a microsecond timestamp, making the
  "cacheable prefix" a guaranteed cache miss); and a FUTURE `since` is clamped to now instead of
  returning 200 with an empty list and a window that has not happened yet. `meta.chars` is now
  measured off the ENCODED stub, so escape-heavy titles no longer under-report the wire size a
  caller budgets against. No migration and no index change: the route's published-id subquery
  was suspected of scanning the corpus, and `EXPLAIN (ANALYZE, BUFFERS)` on production
  disproved it — the planner drives from the windowed event index and probes `articles_pkey`
  per distinct article read, 11 ms against a 79,025-article corpus.

### Added

- **`knowledge_get` now resolves published SYSTEM CANONICALS, and drilling never adds heat at
  any scope (#572).** #569 stopped `knowledge_heat_index` ranking on its own drill hop, but for
  tenant-owned articles only: a canonical's drill stayed counted, because `get_article/3`
  filtered on `tenant_id` and the drill was therefore the sole path to its body. That left the
  index ranking a counted class against an uncounted one on one `heat` number, and since
  drilling is the path the payload itself recommends, following the documentation drove the
  ranking monotonically toward the shared canon. Fixed by giving the canon the read path it
  lacked rather than counting the one it had. **Operator-visible effects:** a canon stub is now
  openable with `knowledge_get` instead of 404ing, and **no backfill runs** — measured on the
  hosted deployment before deciding, not assumed: across 56,033 access events and 23 published
  canonicals there are ZERO `get` (and zero `drill`) rows against a system-scoped article, so
  the migration would have had an empty subject. Before this change the DRILL was the only path
  that could emit a `get` for a canonical, which makes any such row you DO find on your own
  deployment drill-origin and safe to relabel; the rolling window (90 days by default) ages the
  rest out.

- **`meta.chars` / `meta.char_budget` on `heat_index` are BYTES of the encoded stub array**,
  array framing included. They were graphemes summed per stub, so a CJK or emoji payload was
  under-reported several-fold and the brackets and commas were omitted — both in the unsafe
  direction for the one number callers are told to size a cached prefix against. A client that
  sized a buffer off the old figure should re-check it.

- **An explicit `since` on `heat_index` is served verbatim**, where it was rounded up to the
  next UTC day boundary and silently dropped up to 24h of requested reads. The system-derived
  default is still day-snapped, which is what keeps the payload byte-identical between
  refreshes.

- **A heat-projection fault no longer logs raw DB fault text, and only a demonstrable pool exit
  degrades to 429.** The log carried the backend host/port and the failing statement's bound
  parameters; the blanket exit handler reported a node shutdown or any foreign timeout as
  "this tenant is reading too much". Saturation now fails soft as the documented 429 — a pool
  checkout that waited past its deadline, plus the server-side statement timeout (`57014`),
  an exhausted backend (`53xxx`) and one going away or refusing the connection (`57P0x`,
  `08xxx`, including the `08P01` pgbouncer rejects with). Everything else surfaces as what it
  is: a deterministic query fault as a 500, an unreachable database as the 503
  `db_unavailable` every other route already returns. `GET /knowledge/heat_index` documents
  all three.

- **Operator knobs that were live but undiscoverable are now documented (#566):**
  `EXPECTED_APP_NODES`, `STH_SWEEP_CRON`, the fair-share snooze pair
  (`OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS` / `_JITTER`), the per-queue families
  `OBAN_QUEUE_<QUEUE>` and `OBAN_TENANT_FAIRSHARE_<QUEUE>`, `GITHUB_TOKEN`, and the Fly
  secrets-adapter pair `FLY_APP_NAME` / `FLY_API_TOKEN`. Nothing about their behaviour
  changed — they simply could not be found without reading our source. The two that most
  affect a self-hosted install: **`FLY_API_TOKEN` is not injected by anything**, and
  without it (or off Fly entirely) the default secrets adapter refuses every write, which
  fails tenant signup — use `SECRETS_ADAPTER=local_file`; and `GITHUB_TOKEN` left unset
  caps CI-status lookups at GitHub's 60/hour anonymous limit, past which story
  verification reports an API error rather than a CI verdict (set it, or leave it unset —
  a BLANK value 401s every lookup).

  `mix loopctl.check_env_docs` now scans `lib/**/*.ex` alongside `config/runtime.exs` and
  requires a documentation table ROW rather than any mention, so the next such knob cannot
  ship undiscoverable. A name the code BUILDS at runtime still cannot be resolved by a
  textual scan, so the guard now fails on an undeclared dynamic read instead of passing
  over it: those families are documented by hand.

- **A retirement trigger for the US-41.1 legacy embedding columns (#551).** New migration
  (`embedding_retirement_observations`, a global non-tenant table) and a new daily job at
  03:40 UTC. It records one observation per UTC day — the read flag, which legacy columns
  survive, and the cumulative `idx_scan` of every index over them — and once retirement is
  owed it logs at `error` every run and enqueues an operator alert
  (`embeddings.legacy_retirement_due`) through the existing `SCALE_ALERT_WEBHOOK_URL`
  channel, which stays a no-op when that is unset. A passed deadline that a revert in
  progress is BLOCKING alerts on the same channel under `embeddings.legacy_retirement_blocked`
  — it names a condition to resolve, not a column to drop.

  **It drops nothing.** Dropping `articles.embedding` / `memories.embedding` remains a
  deliberate, reviewed migration; this only decides when the system starts asking for one.
  Two triggers, both requiring the columns to still exist: 30 consecutive clear days
  (`embedding_side_table_reads = 1`, no movement on any legacy index), or the `review_by`
  date passing — `2027-01-22`, six months after the cutover. The deadline is what keeps
  the check honest: a probe that errors forever looks exactly like a probe that keeps
  finding nothing. Both values are `config :loopctl, :embedding_legacy_retirement` — no
  new environment variable, and moving the date out is a supported operator decision.

- **`GET /enroll` — a browser page that anchors an EXISTING tenant (#541).** The API
  advertised an `enrollment_upgrade` path out of `agent_rooted`, but nobody could walk it:
  `navigator.credentials.create()` needs a browser, and the only page running a WebAuthn
  ceremony was `/signup`, which creates a NEW tenant. Every tenant predating the signup
  ceremony was therefore permanently locked out of chain-of-custody, work-breakdown,
  dispatch, and token-budget writes. Paste a `user`-role API key, touch an authenticator,
  and the tier flips in place. The key is sent only as a bearer token from your browser to
  the same API you would curl — the page holds no server-side state and enforces nothing;
  every gate stays in `TenantAuthenticatorController`. `GET /api/v1/tenants/me` now names
  the page in `remediation.enrollment_upgrade.enrollment_page` (relative, since a
  self-hosted instance serves its own).

### Fixed

- **WebAuthn registration rejected hardware security keys.** Both browser hooks requested
  `attestation: "direct"` while the server built its challenge with Wax's default of
  `"none"`, so `Wax.register/3` refused any real attestation statement with
  `:invalid_attestation_conveyance_preference`. This was invisible on laptops — Touch ID
  and Windows Hello return `fmt: "none"` regardless — and broke exactly the roaming keys
  (YubiKey and similar) that the signup page recommends. Affects `/signup` as well as the
  new `/enroll`. No configuration change is needed; existing enrolled authenticators are
  unaffected.

- **`WEBAUTHN_RP_ID` / `WEBAUTHN_ORIGIN` / `WEBAUTHN_RP_NAME` — WebAuthn on a self-hosted
  domain (#511, contributed by @FinanceAlex; refs #494).** `config.exs` hardcoded the
  relying party to `loopctl.com`, and the WebAuthn spec requires `rp_id` to be a
  registrable domain suffix of the page's origin — so on any other domain the browser
  refused the enrollment ceremony. Since enrollment is the only way a tenant becomes
  `human_anchored`, a self-hosted deployment could never reach the chain-of-custody
  surface at all. `dev.exs`/`test.exs` already overrode this for localhost; only a prod
  release had no way to. Unset, the hosted deployment is byte-for-byte unchanged.
  Each var applies independently. `WEBAUTHN_ORIGIN` defaults to `https://$PHX_HOST` whenever
  `PHX_HOST` is set — the page host, not the `rp_id`, since `rp_id` may legally be a
  registrable parent domain of it — and must be set explicitly for localhost or a
  non-standard port, since WebAuthn runs only in a secure context (localhost being the one
  `http://` exception). A blank, non-host-shaped `WEBAUTHN_RP_ID` or a `WEBAUTHN_ORIGIN`
  that is not `scheme://host[:port]` is named in the boot log and ignored rather than
  applied; an `rp_id` that is not a registrable suffix of the origin is warned about too.
  Set `WEBAUTHN_RP_ID`
  before the first enrollment: credentials are bound to it, so changing it later
  invalidates every enrolled authenticator.
- **`SCALE_ALERTS_ENABLED` — off switch for a deployment with no alert receiver (#376).**
  Defaults to `true`, so an existing deployment is unchanged. The parse is deliberately
  opt-OUT and asymmetric with loopctl's other boolean env vars: only `false` or `0`
  disable (trimmed, case-insensitive), so a typo leaves alerting **on**, where its guard
  is still watching, rather than silently off. **Disabled stops the whole checker** — the
  supervised `ScaleAlerts` child is not started, so nothing is evaluated, logged *or*
  POSTed; the Prometheus series on `METRICS_PORT` are unaffected and remain the
  degradation signal. Enabling alerting is now a two-part change (`SCALE_ALERT_WEBHOOK_URL`
  **and** this flag) and `/health/ready` reports `checks.scale_alerts: "error"` for either
  half-done direction, naming the setting to fix. The hosted deployment ships this `false`
  via `fly.toml` until an operator webhook receiver exists.
- **`FTS_REGCONFIG` — per-deployment keyword-search language (#492).** Keyword FTS
  was hardwired to the `english` stemmer, so a non-English corpus silently degraded
  (Russian «отчёты» never matched «отчёт»). `Loopctl.Search.Regconfig` is now the
  single source of truth, set from `FTS_REGCONFIG` (default `english`, so the hosted
  instance is unchanged). **Set it before the first `migrate`** — the
  `apply_fts_regconfig` migration bakes the value into the stored `search_vector`s
  and is a no-op on the default. A well-formed but uninstalled config (e.g.
  `ukrainian`) fails the migration loudly rather than building an unusable index.
- **`SECRETS_ADAPTER=local_file` + `SECRETS_FILE` — signup off Fly (#496).** Tenant
  signup stores a per-tenant Ed25519 audit key via `Loopctl.Secrets`, which defaulted
  to the Fly secrets API — so signup was impossible on any other host. The local
  adapter writes `0600` with fsync and atomic tmp+rename under a write lock. Put
  `SECRETS_FILE` on a persistent volume and back it up with the database.
- **Browser signup mints a usable root API key (#500).** The HTML signup ceremony
  previously completed without issuing credentials, leaving a browser-onboarded
  tenant with no authenticated path forward. The key is surfaced exactly once, in
  LiveView memory only — never in a URL, session, or persisted record.

### Changed

- **`GET /api/v1/articles/:id` link payload trimmed, ranked and capped (#538) — BREAKING
  for anything reading `source_article` / `target_article`.** Each link object now carries
  only its FAR side, as `article: {id, title}`. The near side was a constant echo of the
  id already in the request URL, and — because only the far side is preloaded — its
  `title` was always `null`; it cost 14% of a typical response and carried nothing.
  Direction is unchanged and still given by which array the link is in. Links now also
  carry `similarity` when the auto-linker recorded one.
  Both arrays are **ranked** (open `potential_conflict` first, then descending similarity,
  then oldest-first for links with no recorded score — only the auto-linker records one,
  so a hand-created or imported corpus ranks entirely on that fallback) and **capped at 25
  per direction**, with new `links_total` and `links_truncated` fields
  reporting the true size. Use `knowledge_graph` to traverse the whole graph.
  A new `links` query parameter selects the detail level — `full` (default, so an
  untouched caller keeps working), `count` (`links_total` + `links_truncated`, so one
  cheap call answers whether the full fetch is capped), `none` (no link fields).
  An unrecognized value degrades to `full` rather than 422-ing a read.
  `potential_conflicts` is returned in **all three** modes, so a cheaper read never
  silently turns off conflict discovery; it is itself capped at 25 (highest similarity
  first) with `conflicts_total` / `conflicts_truncated`, so a conflict-heavy hub cannot
  make a cheap mode expensive.
  `GET /articles/:id` now also reads the `project_id` / `story_id` query params the MCP
  tool has always advertised, so article-access events are attributed instead of nil.
  As on every sibling knowledge read, a malformed `project_id` there returns **422**
  rather than silently discarding the attribution, and an empty one counts as absent.
  Why: agents are instructed to open every search hit with `knowledge_get`, so this
  response is paid on essentially every wiki read in every session. On a measured hub
  article the links were 12,564 of 16,189 bytes — about 4,000 tokens to read 735 tokens
  of body.
- **Ingestion document content is encrypted at rest (#493).** Raw `content` posted to
  `POST /api/v1/knowledge/ingest` was persisted as plaintext JSON in `oban_jobs.args`
  (including `retryable`/`discarded` rows) until pruning — the one at-rest exposure
  Epic 41 did not cover. It is now Cloak AES-256-GCM encrypted via
  `Loopctl.Ingestion.ContentEnvelope`. `url`, `source_type`, and `metadata` are **not**
  encrypted. Inline `content` is capped at 1,000,000 bytes (`422` over cap).
  `content_hash` changed from `sha256(plaintext)` to a per-tenant HMAC blind index —
  still an opaque deterministic string (dedup unaffected), but no longer an offline
  confirmation oracle for a DB-read attacker.
  **Operational:** when rotating `CLOAK_KEY`, keep the outgoing cipher in
  `retired_ciphers` until the `:ingestion` queue drains, or in-flight jobs discard.

### Fixed

- **Fresh installs no longer break in the Epic-41 migrations (#495).** The pgvector
  guard silently skipped embedding columns that a later migration then required. The
  migration now tolerates and heals the skipped state (idempotent, `IF NOT EXISTS`).
- **`/signup` rendered unstyled and non-functional on a fresh self-hosted install
  (#494)** — the browser pipeline was missing `put_root_layout`. Fixed at the
  `live_session` level so the `layout: false` marketing pages do not double-wrap.

> **Scope of this file.** loopctl's changelog records **operator-facing** changes
> only: environment variables, deploy ordering, migrations with manual steps,
> breaking or behaviour-changing API changes, and security-relevant changes to how
> data is stored. Refactors, test fixes, internal hardening, and dependency bumps
> are deliberately out of scope — `git log --first-parent` is the complete history.
> The trigger is narrow on purpose: a changelog that tries to record every merge
> is the kind that stops being written, which is what happened to the stretch of
> entries between this line and the one below it. See `CONTRIBUTING.md`.

## [Earlier] — 2026-07-16 — Agent-memory substrate: project scope, merged recall, graduation (#411)

### Added

- **Gap 1 — cheap repo → `project_id` resolution.**
  `Loopctl.Projects.resolve_project/2` (`GET /api/v1/projects/resolve`, MCP tool
  `resolve_project`) maps a `repo_url` / `slug` / `name` to a project in one call
  (precedence `slug > repo_url > name`; `repo_url` accepts SSH, HTTPS, and bare
  `owner/repo`). `404` `not_found`, `422` `no_identifier`, `409`
  `ambiguous_resolution` (a fuzzy identifier matched >1 active project).
- **Gap 2 — the `project_id` partition key + merged recall.** Long-term memories
  carry an optional `project_id` that PARTITIONS a subject's memories into a
  `global` (NULL) bucket and one per project — a partition key, NOT the isolation
  boundary (`(tenant_id, subject_id)` remains that, always key-derived). Write
  tenant-validates `project_id` (`422 invalid_project_id`); recall merges
  `global ∪ active-project` and treats an unowned id as an empty partition
  (global-only, no error). `Loopctl.Memory.recall_context/2`
  (`POST /api/v1/recall`, MCP tool `recall_context`) returns ONE re-ranked
  `global ∪ active-project` union of long-term MEMORY *and* KNOWLEDGE (combined
  search summaries), each result tagged `source: memory|knowledge`, plus the
  untouched per-source envelopes. A blank/over-500-char query is a `422` up front;
  a one-sided degrade returns the other side with `meta.degraded?: true` (never a
  500). Agent role is forced to published articles + own/`shared` memories (#163).
- **Gap 3 — recall-count graduation (HOT memory → durable knowledge).** Recall now
  bumps a `recall_count`/`last_recalled_at` hotness signal off the hot path
  (relevance floor `memory_recall_bump_min_score` = 0.6, cooldown
  `memory_recall_bump_cooldown_seconds` = 3600 s, fan-out cap
  `memory_recall_bump_max_tasks` = 200). The hourly
  `Loopctl.Workers.MemoryGraduationSweepWorker` graduates not-yet-graduated
  memories at/above `memory_graduation_recall_threshold` = 3 recalls into curated
  knowledge articles via the novelty gate (per-run budget
  `memory_graduation_max_per_run` = 50, scan fan-out
  `memory_graduation_scan_limit` = 500), stamping `graduated_at` on any durable
  verdict (a fell-open gate is not stamped — it re-graduates once embeddings
  recover).
- **Gap 3 surface — explicit, on-demand graduation.**
  `Loopctl.Memory.graduate_memory/3` is now reachable over HTTP + MCP:
  `POST /api/v1/memory/graduate` `{memory_id, re_scope?}` (MCP tool
  `memory_graduate`). Scope is key-derived (a foreign/unknown `memory_id` → `404`,
  no cross-subject oracle; malformed → `422 invalid_memory_id`). The novelty-gate
  verdict drives the status: `created`/`gated_to_draft` → `201` with a new
  article, `duplicate`/`deduplicated` → `200` (canonical article, nothing
  created). `re_scope: "global"` promotes a PROJECT memory to a tenant-wide
  article on its FIRST graduation only (`409 already_graduated` otherwise); a
  fell-open gate returns `503 gate_unavailable`. Allowlisted as an agent-reachable
  write in the default-deny custody classification (alongside `memory_promote` /
  `knowledge_create`).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the
  project-scope partition model, `resolve_project`, merged `recall_context`, the
  recall-count graduation cadence, and `memory_graduate` + local→global re-scope;
  `mcp-server/README.md`, `AGENTS.md`, and both changelogs updated. The
  MCP server publishes these three new tools at `loopctl-mcp-server` **2.42.0**.

## [Unreleased] — 2026-07-11 — OKF-curated + RAG Hybrid Knowledge Retrieval (Epic 31)

### Added

- **Hybrid knowledge retrieval** — `Loopctl.Knowledge.hybrid_search/3`
  (`POST /api/v1/knowledge/hybrid_search`, MCP tool `knowledge_hybrid_search`)
  composes the already-shipped retrieval (`search_combined/3`) and curated-source
  identification (`list_curated_sources/2`, US-31.1) subsystems into a single
  resolution layer: `:curated` wins ONLY when a governed curated source's
  ABSOLUTE (never pool-relative, min-max-normalized) confidence score clears a
  scale-matched threshold AND beats the best retrieved candidate by a margin AND
  is authoritative (published, not superseded, not in an open
  `:potential_conflict`); otherwise `:retrieved`. Both branches return an
  identical `results`/`meta` key shape carrying `meta.provenance`
  (`:curated`/`:retrieved`), `meta.confidence`, and `meta.curated_article_id` — a
  caller branches on `meta.provenance` alone, never on which subsystem answered.
  See [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md).
  - **Curated-source identification** (US-31.1) — a GOVERNED, non-self-assignable
    `articles.curated_at`/`curated_by` marker (excluded from `@cast_fields`),
    written only by `Knowledge.mark_curated/3` / `unmark_curated/3` (audited).
    Content edits (title/body/publish) invalidate the marker, forcing
    re-curation. `list_curated_sources/2` applies system-scope precedence (a
    tenant's own curated answer always wins over a `scope: :system` canonical on
    the same topic) and excludes superseded/conflicted articles.
  - **Progressive disclosure** (US-31.3) — `Knowledge.progressive_index/3` /
    `progressive_drill/3` (`GET /api/v1/knowledge/progressive_index` /
    `GET /api/v1/knowledge/progressive/:id`, MCP tools
    `knowledge_progressive_index` / `knowledge_progressive_drill`): a bounded,
    top-K-capped topic index of compact stubs (curated-preferred, one hop of
    `:relates_to` hub enrichment), then a full-body drill.
- **Docs** — new
  [`docs/knowledge-hybrid-retrieval.md`](docs/knowledge-hybrid-retrieval.md) (the
  resolution rule, provenance contract, progressive disclosure, and the
  three-layer model positioning hybrid retrieval within the Knowledge Wiki
  alongside Agent Memory and the Context Retriever); README/CLAUDE.md/AGENTS.md
  extended. **#305 and #306 describe the same feature** — recommend closing one
  as a duplicate rather than tracking separately; the "#305 reconcile
  `docs/cole-medin-self-evolving-wiki.md`" item is already satisfied by the
  epics 28–30 reconciliation (KB hub `fb9abd73`/`3ee5f890`).

### Verification

- **Terminal e2e + negative control** (US-31.5,
  `test/loopctl/knowledge/hybrid_e2e_test.exs`) — a governed curated
  refund-policy article suppresses an unrelated fuzzy chunk (`:curated`, hoisted
  first); archiving that curated article (removed from the published search
  pool, unrelated chunk unchanged) flips the result to `:retrieved` and surfaces
  the previously-suppressed chunk, proving causation; a niche non-curated topic
  falls to `:retrieved`; a near-but-wrong curated doc is never mislabeled
  `:curated`; `:curated`/`:retrieved` meta share an identical key shape. Tenant isolation is proven across the resolver, progressive index/drill,
  and the HTTP API; a system-scoped curated article participates without
  overriding a tenant's own; a superseded/conflicted curated article is never
  authoritative without the conflict surfaced.

## [Unreleased] — 2026-07-10 — Context Retriever (Epic 30)

### Added

- **Context Retriever** — a governed, auto-generated agent query surface over
  loopctl's own STRUCTURED records (`projects`/`stories`/`epics`), the third of
  loopctl's three agent information layers (Knowledge Wiki / Agent Memory /
  Context Retriever). See [`docs/context-retriever.md`](docs/context-retriever.md).
  - **Entity registry** (`Loopctl.ContextRetriever.Entity`/`Registry`, table
    `entity_definitions`) — a tenant admin declares a named **entity** (typed
    `fields` + a backing source) over `POST/PATCH/DELETE /api/v1/entities`. The
    definition IS the executor's field allowlist, bounded by a SERVER per-source
    column allowlist that excludes `tenant_id`/`metadata`/custody columns. Defining
    requires role ≥ `user` + a human-anchored tenant; per-tenant entity count and
    fields-per-entity are capped. Relationships/joins are out of scope for v1.
  - **Tool generator** (`ToolGenerator`) — emits per-entity `cr_filter_<entity>_by_<field>`
    tools (one per filterable field) and a `cr_search_<entity>` tool when a declared
    searchable TEXT field is covered by the source's `search_vector`; served at
    `GET /api/v1/retrieve/tools`.
  - **Executor** (`Executor.run/3`, the security boundary) — `POST /api/v1/retrieve/:entity`
    runs a filter/search parameterized (Ecto-pinned values / `websearch_to_tsquery`
    — never model SQL), dual tenant-scoped (RLS `loopctl_app` role + explicit
    predicate), execute-time allowlist-rechecked, shaped to declared columns only,
    audited fail-closed (`audit_log` `entity_type: "context_retrieval"`; no rows
    without a persisted audit trail), and per-tenant rate-limited (429 over-limit,
    unexecuted). Injection payloads match literally; pagination size + offset are
    capped.
- **MCP dynamic tool listing** — `mcp-server/lib/generated-tools.js` fetches the
  tenant's `cr_*` specs, appends them to ListTools (TTL-cached, negative-cached on
  outage, non-`cr_`/static-colliding specs dropped), and dispatches a `cr_*` call
  to `POST /api/v1/retrieve/:entity` under the same agent key as static reads.
- **Docs** — new [`docs/context-retriever.md`](docs/context-retriever.md) (the
  three-layer model, architecture, security model, surfaces); README/CLAUDE.md/AGENTS.md
  extended to a three-way `retrieve_*` vs `knowledge_*` vs `memory_*` decision
  guide. The #309 "reconcile `docs/cole-medin-self-evolving-wiki.md`" item was
  already satisfied (removed PR #310; content in KB hub `fb9abd73`); the epic folder
  is `epic_30`.

### Verification

- **Terminal e2e + security** (US-30.7) — `Loopctl.E2E.ContextRetrieverJourneyTest`
  (define → ListTools → filter + search via API and the MCP-derived body agree,
  tenant-scoped) and `Loopctl.E2E.ContextRetrieverSecurityTest` (injection in
  filter + search match literally; non-allowlist rejected on every surface;
  cross-tenant define/list/query isolation via context/API/MCP with a positive
  control; no undeclared-column leak; an audit record per execution; `/retrieve`
  429 over-limit) — both run under the non-owner app role. All Context Retriever
  endpoints render at `/swaggerui`.

## [Unreleased] — 2026-07-10 — Agent Memory auto-promotion (Epic 29, Part 2)

### Added

- **Memory promotion pipeline** — compiles a session's short-term turns into durable
  long-term `:promoted` memories without an explicit agent write. Triggered explicitly
  (`POST /api/v1/memory/promote {session_id}` → `Loopctl.Memory.promote_session/1`) or
  by the all-tenants cron `Loopctl.Workers.MemoryPromotionSweepWorker`; both enqueue the
  per-session `Loopctl.Workers.MemoryPromotionWorker` (unique per
  `(tenant_id, subject_id, session_id)`).
  - **Idempotency spine** — a `session_promotions` watermark (session content hash) skips
    an unchanged session WITHOUT an LLM call; re-running promotion adds no net rows
    (measured including superseded).
  - **Confidence gate + hash dedupe/supersede** — survivors above the confidence
    threshold are written with their `confidence`, embedded synchronously at write time,
    exact-deduped on `embedding_content_hash`, and near-dup superseded (source-scoped to
    `:promoted`, never clobbering an `:explicit` memory).
  - **Per-tenant budget** — a compiles/hour cap (atomic reservation incl. in-flight jobs)
    returns HTTP 429 with NO LLM call when exceeded.
  - **TTL-window invariant** — `sweep_interval < sweep_window < session_ttl`, sweep
    promotes oldest-active-first to bound the golden-nugget-loss window.
  - **Prompt-injection resistance** — session content is scope-enforced (the LLM never
    sees foreign turns) and `cross_links` are tenant + visibility validated, so a
    compromised model's foreign/fabricated article link is stripped before write.
- **MCP tool** — `memory_promote` (compile a session; caller's own sessions only; scope
  key-derived). The `/api/v1/memory/promote` endpoint renders at `/swaggerui`.
- **Promotion-quality eval (US-29.5)** — `Loopctl.Memory.PromotionEval` scores the
  compiler's precision/recall against a committed labeled dataset under a reserved,
  structurally-excluded eval subject; calibration only, never gates promotion.
- **Telemetry** — `[:loopctl, :memory_promotion, *]` events (`:swept` `:skipped`
  `:compiled` `:gated_out` `:promoted` `:superseded` `:degraded` `:quota_exceeded`
  `:budget_exceeded` `:failed` `:eval`) so a failing/budget-walled/degraded sweep is
  observable, not silent.
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md) extended with the full
  promotion lifecycle, the watermark/budget/TTL invariants, the confidence + eval story,
  the prompt-injection stance, and the Claude Code Stop-hook recipe (cross-ref
  `mkreyman/claude-config#85`, not implemented here);
  [`docs/observability/promotion.md`](docs/observability/promotion.md) documents the
  pipeline metrics.

### Verified (US-29.6, terminal)

- **Promotion e2e** (`Loopctl.Memory.PromotionE2ETest`) — a session promoted via
  `POST /api/v1/memory/promote` is recall-able through BOTH the context and the API with
  `source: :promoted`, `source_session_id`, and `confidence`.
- **Idempotency + cross-scope** (`Loopctl.Memory.PromotionIsolationTest`) — re-promotion
  (explicit + sweep) adds no net rows counting superseded (watermark skip); a promoted
  `(tenant T, subject A)` memory is invisible to tenant U AND subject B via context, API
  (recall / index / forget), with MCP scope-blindness proven in
  `mcp-server/test/memory_tools.test.js`.
- **Unattended safety** (`Loopctl.Memory.PromotionSafetyTest`) — injection produces no
  cross-tenant-linked memory; an over-budget promote is 429 with no LLM call; a compile
  failure emits `:failed` telemetry.

## [Unreleased] — 2026-07-09 — Agent Memory (Epic 28, Part 1)

### Added

- **Agent memory subsystem** — a per-agent PRIVATE working memory, isolated per
  `(tenant_id, subject_id)` and kept strictly separate from the shared Knowledge
  Wiki. Two tiers:
  - **Session memory** (`session_memories`) — short-term, append-only, chronological
    turns/facts with a required `expires_at`, pruned by
    `Loopctl.Workers.SessionMemoryPruneWorker`. No embedding.
  - **Long-term memory** (`memories`) — durable facts embedded as `vector(1536)`
    (populated asynchronously by `Loopctl.Workers.MemoryEmbeddingWorker`) and
    recalled by HNSW cosine similarity, with a supersede/forget lifecycle and a
    per-`(tenant, subject)` live-row quota.
- **HTTP API** — `POST /api/v1/memory` (remember), `POST /api/v1/memory/recall`
  (semantic recall; degrades to a scoped text match, never a silent empty),
  `GET /api/v1/memory` (list; superadmin `?all_subjects=true` oversight), and
  `DELETE /api/v1/memory/:id` (forget). Scope is derived from the API key, never the
  body; the endpoints render at `/swaggerui`.
- **MCP tools** — `memory_remember`, `memory_recall`, `memory_list`, `memory_forget`
  (four tools; scope key-derived, no `tenant_id`/`subject_id` surface).
- **Docs** — [`docs/agent-memory.md`](docs/agent-memory.md): architecture, the two
  tiers + session TTL/pruning, the `subject_id` derivation + BYPASSRLS heavy-read
  structural guard, when to use memory vs knowledge (vs the future context
  retriever), the PII/secret (BYO-embedding) stance, and the auto-promotion (#308) /
  skills-consumer (`claude-config#85`) seams.

### Verified (US-28.5, terminal)

- End-to-end (write via API → recall via context AND API), cross-surface isolation
  (cross-tenant AND cross-subject invisible/immutable across context, API, and MCP,
  on both the semantic and fallback paths), and an `@tag :scale` recall gate proving
  a needle subject recalls its own top-k among an ~80k multi-subject corpus (the
  over-fetch pool + outer subject filter does not starve a subject at scale).

## [Unreleased] — 2026-07-03 — per-tenant BYO Anthropic LLM config + usage (Epic 28, #179)

### Added

- **Per-tenant BYO Anthropic config** — `GET` / `PATCH /api/v1/tenants/me/llm-config`
  (role `:user`): each tenant supplies its OWN Anthropic API key (encrypted at rest,
  never returned — only `has_api_key` + a last-4 hint) and picks a model per operation
  (`extraction_model` / `classification_model` / `merge_model`). loopctl fronts no LLM
  cost. Setting/rotating a key writes an audit event (without the value).
- **Per-tenant LLM usage tracking** — `GET /api/v1/knowledge/llm-usage`
  (role `:orchestrator`): token usage grouped by operation + model + source_type + day
  over an optional date range, with offset/limit pagination (default 90-day lookback).
  Record-only — no budget enforcement.

### Changed — BREAKING (mandatory BYO)

- **Tenant knowledge-LLM work now REQUIRES a per-tenant Anthropic key.** Content
  ingestion, category classification, article merge, and review-finding extraction all
  resolve the tenant's OWN key via `Loopctl.Llm.resolve/2` — there is **no**
  global-system-key fallback. The global `ANTHROPIC_API_KEY` / `:anthropic_provider`
  config path was removed.
- With no key configured, `POST /knowledge/ingest[/batch]` returns **422** with
  `code: "no_api_key"` and a remediation hint; the Oban workers `{:discard}` cleanly
  (no crash, no retry loop). A `[:loopctl, :llm, :blocked]` telemetry event and an
  `llm.blocked_no_api_key` audit entry are emitted when a tenant is blocked.
  (Single-tenant today; no grace period — the operator sets a key.)

## [Unreleased] — 2026-06-30 — docs sync + agents'-KB endpoints backfill

### Added

- **KB conflict resolution API** — `GET /api/v1/knowledge/conflicts` (list potential-conflict
  article pairs the auto-linker/nightly lint flagged as too-similar-to-coexist) and
  `POST /api/v1/knowledge/conflicts/resolve` (record a `dismiss`/`supersede`/`merge` verdict;
  the nightly executor acts on `supersede`/`merge` only at `confidence: high`, and `merge`
  LLM-synthesizes both sources into one new draft, never auto-published). Role: agent.
  MCP tools `knowledge_conflicts`, `knowledge_resolve_conflict` (MCP 2.26–2.28).
- **`GET /api/v1/knowledge/analytics/retrieval-metrics`** — daily retrieval-precision time
  series (share of search results the agent then opened). Role: orchestrator. MCP tool
  `knowledge_retrieval_metrics` (MCP 2.29).
- **`GET /api/v1/knowledge/curation-log`** — human-readable feed of KB curation adjustments
  (novelty-gate `gate_duplicate`/`gate_draft`; conflict `supersede`/`merge`/`dismiss`),
  recorded only while a tenant has `settings.kb_curation_log` enabled (default off).
  Role: orchestrator. MCP tool `knowledge_curation_log` (MCP 2.30).
- **Creativity primitives** — `POST /api/v1/knowledge/novelty`, distant-pairs, random-walk,
  and suggested-links endpoints (MCP `knowledge_novelty`, `knowledge_distant_pairs`,
  `knowledge_random_walk`, `knowledge_suggest_links`).
- **API root discovery links** — `GET /api/v1/` now also returns `discovery`, `routes`, `wiki`,
  and `mcp_server` pointers so agents hitting the root have a path to the MCP server and
  discovery documents instead of dead-ending.

### Docs

- Corrected the MCP tool count to **69** (was 57/65) across the README, `mcp-server/README.md`,
  the landing/docs pages, and `CLAUDE.md`, and documented the 4 previously-undocumented tools.
- Fixed drifted docs: UI-test endpoints are nested under `/projects/:project_id/ui-tests`
  (README); `verified_status` values are `unverified`/`verified`/`rejected` (not `pass`/`fail`),
  and `initial_verified_status` on import is honored only for a superadmin caller
  (orchestration guide); `knowledge_export` has no `obsidian` format and its download needs a
  user key (`mcp-server/README.md`); `GET /` serves the HTML landing page (it does not redirect).
- `GET /api/v1/routes` is now described as a curated index (not the exhaustive surface), points
  to the OpenAPI spec, and lists the CoC v2 dispatch routes, `recover-cap`, `acceptance_criteria`,
  and the new knowledge endpoints.
- Refreshed `model_name` examples (OpenAPI schema, MCP tool descriptions, PRD) to the current
  `claude-sonnet-5` id. `model_name` remains a free-form string and cost is caller-reported, so
  no code change is needed to record a new model.

## [Unreleased] — 2026-06-25 — heavy-read pgbouncer outage fix (US-27.13)

### Fixed

- **HeavyReadRepo pgbouncer `08P01` outage (US-27.13):** the dedicated heavy-read pool
  carried a `statement_timeout` connection STARTUP parameter (`parameters:` in
  `config/runtime.exs`), which Fly MPG's pgbouncer rejects with
  `FATAL 08P01 unsupported startup parameter`, crash-looping the pool so it never
  established a connection — every heavy vector/enumeration endpoint (`suggested_links`,
  semantic search, `distant_pairs`, `novelty`, heavy enumeration) hung then `503/504`'d.
  It was invisible to CI because the suite connects to direct Postgres (which accepts the
  startup param) and aliases heavy reads to `AdminRepo`. The server-side `statement_timeout`
  is now applied per-read via `SET LOCAL` inside a transaction (the pgbouncer-safe mechanism).

### Changed

- **Heavy-read `statement_timeout` configuration:** set via `HEAVY_READ_STATEMENT_TIMEOUT_MS`
  (default 10s) and the per-endpoint `:heavy_read_statement_timeout_overrides` map, applied
  per-read via `SET LOCAL` — **NOT** a connection startup `:parameters` value
  (pgbouncer-incompatible). A server GUC that must persist at connect is set via `ALTER ROLE`
  (the documented `hnsw.ef_search` lever), never a startup parameter.

### Added

- **Recurrence guards:** `config_pgbouncer_safe_parameters_test.exs` (scans the config
  source — incl. `runtime.exs` — and fails on any pgbouncer-incompatible repo `:parameters`)
  and a pgbouncer-layer e2e (`pgbouncer_startup_params_test.exs` + a CI `pgbouncer-e2e` job
  that gates deploy) which reproduces the `08P01` rejection and proves `SET LOCAL` enforces
  through the proxy.

## [Unreleased] — 2026-06-22 — knowledge wiki harvest-hardening (#132–#138)

A batch of Knowledge Wiki API changes for reliable agent/harvest workflows.
(Supersedes the #120 draft-by-default + orchestrator-publish-gate notes below.)

### Added

- **Idempotency_key (#137):** `POST /api/v1/articles` accepts `idempotency_key`
  (per-article, max 255). Re-creating with the same key is a no-op that returns
  a reference to the existing article (`deduplicated: true`, id only — no body),
  preventing partial duplicates on re-capture. Distinct from
  `source_type`/`source_id` (a shared source identifier).
- **Lag-free enumeration (#134/#135):** `GET /api/v1/articles` filters by
  `source_type`, `source_id`, and `idempotency_key`; new MCP `knowledge_list`
  wraps it. This is the lag-free, all-status read of record for
  dedup/idempotency/repair — vs `knowledge_search`, which is ranked,
  published-only, and lags writes.
- **Bulk delete (#136):** `POST /api/v1/knowledge/bulk-delete` (role user) —
  partial-success soft-delete by `article_ids`, `source_type`+`source_id`, or
  `tag`+`confirm:true` (exactly one selector). MCP `knowledge_bulk_delete`.
- **Ingest publish opt-in (#133):** `POST /api/v1/knowledge/ingest` + `/batch`
  accept `publish: true`; extracted articles stay **draft by default**
  (lower-trust LLM output) but can be published in one step.

### Changed

- **Publish-on-create is the default for every role, including agent (#133)** —
  `POST /api/v1/articles` publishes immediately; draft is now the opt-in
  (`draft: true` / `status: "draft"`). The orchestrator-only publish gate is
  removed on the create path (publishing a wiki article is neither destructive
  nor story chain-of-custody); the standalone publish endpoint and system-scope
  gate are unchanged.
- **Bulk-publish is partial-success + uncapped (#132, #138.3):** publishes every
  valid draft and returns per-id outcomes (published/skipped/not_found/errored)
  in `meta.results` instead of failing the whole call; already-published ids are
  skipped (idempotent); the 100-id cap is gone (auto-chunked, ≤5000).
- **Tag cap raised 20 → 50 (#138.2).**

### Fixed

- **Invalid `?status=`/`?category=` → 400 with allowed values (#138.1)** on
  `GET /api/v1/articles` (was a 404/500 from an `Ecto.Enum` cast); malformed
  list/map query params no longer 500.
- **429 `Retry-After` is always ≥ 1s (#136)** (was `reset_at - now`, which could
  be ≤ 0 at a window boundary); rate limits documented on `RateLimitError`.

### Docs

- Documented the witness/STH request-header workflow for non-MCP clients (#138.4)
  and the search-vs-list distinction.

## [Unreleased] — 2026-06-19 — create-and-publish + draft note (#120)

### Added

- `POST /api/v1/articles` accepts `publish: true` to create-and-publish in one
  call. This is gated at **orchestrator+** (mirrors `POST /articles/:id/publish`);
  an agent requesting publish gets `403 publish_requires_orchestrator`.

### Changed

- The create response now carries a `note` making the lifecycle explicit —
  articles are created as **draft** (not visible in search/index/context) unless
  published, which the two-step flow made easy to miss (#120).

### Security

- The initial article status is now set **server-side** on create; a
  caller-supplied `status` is ignored except that `status: "published"` is
  treated as `publish: true` (and gated the same way). This closes a gap where
  an agent could self-publish — or set `archived`/`superseded` — by passing
  `status` directly in the create payload, bypassing the orchestrator publish
  gate.

## [Unreleased] — 2026-06-19 — search total_count semantics (#119)

### Changed

- `GET /api/v1/knowledge/search` now returns `meta.total_count_scope` (and
  `meta.search_mode`) so callers can tell what `meta.total_count` counts in the
  active mode: `keyword_matches` (stop-word-filtered tsquery matches),
  `ranked_corpus` (semantic ranks all embedded published articles — that
  embedded set's size, not a match count, and ≤ the published count),
  `merged_candidates` (combined: deduped union of a keyword and a semantic
  sub-search, each capped at 50, so up to ~100), or `filtered_set` (list mode:
  complete set). The
  OpenAPI description and MCP tool docs now spell out the per-mode semantics and
  stop-word behavior, and direct corpus-sizing to list mode or
  `GET /knowledge/stats` (#119). No value changed — `total_count` was already
  uncapped per mode; this makes its meaning explicit.

## [Unreleased] — 2026-06-19 — knowledge stats endpoint (#118)

### Added

- `GET /api/v1/knowledge/stats` (and `GET /api/v1/projects/:project_id/knowledge/stats`)
  — aggregate article counts (`total`, `by_category`, `by_status`) via cheap
  `COUNT(*) GROUP BY` with no article metadata loaded. Answers "how many
  articles are here?" without paging the index. Counts span all statuses;
  `by_status` shows the published/draft/archived/superseded split. Role: agent+.
  Exposed via the MCP `knowledge_stats` tool.

## [Unreleased] — 2026-06-19 — knowledge_index field projection (PR #126)

### Added

- `GET /api/v1/knowledge/index` accepts a `fields` query param — a
  comma-separated projection of `id, title, category, tags, status,
  updated_at`. `id` and `category` (the grouping key) are always included;
  unknown fields return `400` (matching the existing `category` validation).
  `meta` now echoes the applied `fields` and adds `has_more` (a synonym for the
  existing `truncated`). The MCP `knowledge_index` tool gains a matching
  `fields` parameter (array or csv). Non-string `fields`/`category`/`tags`/
  `limit`/`offset` params now return `400`/are ignored rather than raising a
  `500`.

### Changed

- **Default response shape changed** (intentional): without `fields`, each
  article object now includes only `id, title, category` instead of all six
  metadata fields. This shrinks the catalog payload dramatically — previously
  the index serialized every field (including the full `tags` array) for up to
  1000 articles per page, producing ~545 KB responses that overflowed MCP
  clients' token limits (#117). Callers that need `tags`/`status`/`updated_at`
  must now request them explicitly via `fields`.

## [Unreleased] — 2026-06-18 — Concurrent article create (PR #116)

### Changed

- `POST /api/v1/articles` (and MCP `knowledge_create`) is now concurrency-safe.
  A create that races/retries into the `(tenant_id, title)` active unique index
  no longer returns a spurious `422 "tenant_id has already been taken"`: an
  **identical-body** collision returns the existing article idempotently as
  **HTTP 200**, and a **different-body** collision returns **`409 title_conflict`**
  (with `existing_article_id`) instead of a 422 the client retries into. The
  unique-violation is attributed to `title` rather than the misleading
  `tenant_id`. Fixes #113/#114.

## [Unreleased] — 2026-04-17 — Import merge + agent ergonomics (PR #105)

### Added

- `POST /api/v1/projects/:project_id/stories` — create a single story by
  epic number (agent-friendly alternative to the UUID-based
  `POST /epics/:epic_id/stories`). Role: `:orchestrator`.
- `POST /api/v1/stories/:id/backfill` — mark a story as verified when the
  work was completed outside loopctl. Records provenance in
  `metadata.backfill` plus an `action: "backfilled"` audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch lineage
  (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — this is the
  structural guard that makes backfill safe regardless of role. Role:
  `:orchestrator`.
- `story.backfilled` added to the webhook event allowlist.

### Fixed

- `POST /api/v1/projects/:id/import?merge=true` no longer returns
  `epics[0].tenant_id: has already been taken for this project` when
  clients serialize epic numbers as strings. Epic numbers are normalized
  to integers (and story numbers to strings) before validation and DB
  lookups.
- Fallback changeset rendering translates Epic/Story unique-number
  violations into `"Epic 72 already exists in this project. Use
  merge=true..."` regardless of which controller surfaced the error.

### Changed

- Data-op roles: create/update for epics, stories, and dependencies
  lowered from `:user` to `:orchestrator`. DELETE stays at `:user` per
  the destructive-op rule. CLAUDE.md Security section clarified.
- `/loopctl:orchestrate` skill carves out "data operations" (imports,
  creates, backfills, dispatches, reads) as operations the orchestrator
  can perform directly without dispatching a sub-agent. Sub-agents are
  only required for editing application code.

### Security

- `unique_constraint` error translation now scopes to the `_number_`
  index specifically, so future unique constraints (external_id, slug,
  etc.) on Epic/Story schemas won't be mis-reported as "X already
  exists."

## [1.0.0] — 2026-04-12 — Chain of Custody v2

27 stories across 7 phases implementing a six-layer trust model for
AI agent development loops. Full spec: `docs/chain-of-custody-v2.md`.

### Added — Chain of Custody v2 / US-26.0.1

- **Tenant signup ceremony with WebAuthn enrollment**.
  - New public LiveView at `/signup` that collects tenant metadata and
    initiates a FIDO2 registration ceremony via `navigator.credentials.create()`.
    Supports both cross-platform authenticators (YubiKey, etc.) and platform
    authenticators (Touch ID, Windows Hello).
  - `tenant_root_authenticators` table storing `credential_id`, COSE public
    key, attestation format, sign counter, and friendly label per enrolled
    key. One-to-many from tenant to authenticator, unique on
    `(tenant_id, credential_id)`, RLS-enabled.
  - `tenants.status` gains a `:pending_enrollment` value; an Oban cron
    worker (`PendingEnrollmentCleanupWorker`, every 5 minutes) deletes
    tenants stuck in that state past the 15-minute TTL.
  - `Loopctl.WebAuthn.Behaviour` + `Loopctl.WebAuthn.Wax` adapter, wired
    via config-based DI so tests can swap in `Loopctl.MockWebAuthn`.
  - `Loopctl.Tenants.signup/1` atomically creates the tenant, persists
    every verified authenticator, flips the status to `:active`, and
    writes the audit log genesis entry in a single `Ecto.Multi`.
  - OpenAPI schemas: `TenantSignupRequest`, `WebAuthnChallenge`,
    `WebAuthnAttestation`; `TenantResponse` updated to surface the new
    `pending_enrollment` status.
  - New post-signup onboarding LiveView at `/tenants/:id/onboarding`
    that scaffolds the four-step operator checklist (audit key
    generation, system article tour, first project, first agent).
  - JavaScript `WebAuthn` hook in `assets/js/hooks/webauthn.js`.
  - `CoreComponents` module providing `<.input>`, `<.icon>`, and
    `<.flash_group>` in the design-system palette.

### Removed

- `POST /api/v1/tenants/register` and the `Loopctl.Auth.register_tenant/1`
  helper it called. Chain of Custody v2 requires a WebAuthn-gated signup
  ceremony; the legacy unauthenticated tenant creation path has no
  replacement and any request to it now 404s. This enforces AC-26.0.1.7.
