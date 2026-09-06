# Changelog

All notable changes to `loopctl-mcp-server` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## 2.80.0 — 2026-09-05 (a destructive tool stops carrying its own approval)

### Changed

- **BREAKING: `knowledge_bulk_delete` no longer declares a `confirm` argument, and the
  `tag` selector is two-step even for the soft archive (#779).** `confirm` was
  authorization the model wrote for itself: the same call that asked for the mutation
  also carried its own approval, so nothing outside the caller ever saw the proposal, and
  an agent that decided to archive every article carrying a tag also decided to confirm
  it. The parameter is gone from the tool schema and from the request body this server
  sends. A request that still carries a `confirm` key is refused by the API with `400`
  and `error.code: "confirm_removed"` — refused rather than ignored, so a stale client
  learns the gate moved instead of believing it passed one.

- **The `tag` archive now uses the frozen-token flow the hard delete already used.** Call
  with `dry_run: true` to get `meta.would_affect` and a single-use, TTL-bounded
  `meta.token` frozen over the previewed id-set, then call again with the same `tag` plus
  that token to archive exactly that set — rows that started matching after the preview
  are never swept. A `tag` call with neither `dry_run` nor a `token` is `400` with
  `error.code: "dry_run_required"`. A selector too large to freeze gets `meta.oversized`
  and `meta.confirm_hash` instead; echo the hash back with the same selector and the
  server re-resolves and refuses on any drift. The archive and delete flows mint
  DIFFERENT token types, and the oversized `confirm_hash` is keyed on the op, so an
  archive proposal is not spendable as a delete or the reverse at any set size. Every token
  is bound to its SELECTOR too — the hard delete as much as the tag archive — so replaying
  one under a different `tag` is a `400`, not a silent sweep of the tag it was minted for,
  and a hard delete replays the same selector it previewed rather than the token alone. A
  selector that matches nothing needs no token — it stays a `200` no-op on either path.
  A proposal minted by an earlier server release is refused after the API deploy (a
  fail-closed `400`); re-run the dry-run.

- **Unchanged:** `article_ids` and `source_type` + `source_id` still archive immediately
  with no token, because each names a set the caller already holds. The role gate is
  still `LOOPCTL_USER_KEY`. The response shape, including `meta.counts`/`meta.results`,
  is the same.

### Notes

- The design invariant this enforces — no loopctl MCP tool takes a `confirm`, `approved`
  or `yes` argument, and a set-based destructive action returns a server-minted proposal
  the caller replays — is now written down in `README.md` so the next destructive tool
  inherits it rather than re-deriving it.

## 2.78.0 — 2026-08-28 (the corpus tier becomes reachable from an agent)

### Added

- **`corpus_search`, `corpus_create`, `corpus_index`, `corpus_list`, `corpus_status`,
  `corpus_delete`** — the Epic 43 CORPUS TIER: an index over reference documents whose
  FILES stay in your own repo. loopctl holds chunk pointers (and, in mode A, the text it
  embeds); a search returns `{source_ref, locator, snippet, score}` and NEVER the chunk
  body, so the next step is always to open the file yourself. The HTTP surface shipped in
  US-43.1/43.2/43.3; until now it was reachable only by hand.

  **Which tool, and when.** `corpus_search` when you need the VERBATIM text of an
  authoritative document — a spec, a contract, an RFC. `knowledge_search` when you want
  what we LEARNED about a topic. Searching the wiki for a distillation of a document whose
  exact wording you needed is the failure this tier exists to prevent; so is reading an
  empty wiki result as an empty corpus.

  **Two modes, pinned at `corpus_create`.** `server_embedded` takes chunk TEXT and embeds
  it on YOUR key, so a tenant with no embedding credential is refused at create
  (`422 no_embedding_key`) rather than at first index, and both search lanes work.
  `client_embedded` takes VECTORS and loopctl stores content it cannot read: no embedding
  key, SEMANTIC-ONLY search, `allow_snippets` defaults to FALSE, and a chunk carrying
  `text` is refused (`422 text_not_accepted`) rather than silently ignored. Every mode
  restriction is stated in the tool DESCRIPTION — a caller should never discover one from
  an error.

  `corpus_index` carries `source_complete` in both of its forms (a bare `source_ref`
  string, or `{source_ref, locators}` for a document spanning several batches). It is the
  only way to prune what a re-indexed document no longer contains; without it on the tool
  surface, stale chunks would survive forever.

  `corpus_delete` is the ONE verb here that needs `LOOPCTL_USER_KEY`: set-based AND
  irreversible, the same AND that puts the knowledge bulk ops behind a user key.

### Notes

- **`corpus_search` is deliberately NOT part of `recall_context`** and is never
  auto-injected into a session. Verbatim spec chunks in every repo's recall pack are
  exactly the pollution the corpus tier's separate tables prevent by construction.
- Path building AND request-body building for every corpus tool live in
  `lib/http-helpers.js`, so the test suite exercises the code this server ships rather
  than a mirror re-implemented inside a test file.

## 2.76.0 — 2026-08-21 (contest an article you just refuted)

### Added

- **`knowledge_assert_conflict`** — assert a conflict between two articles the system never
  flagged. `knowledge_resolve_conflict` could only reach pairs the AUTO-LINKER flagged by
  cosine similarity, which is precisely the wrong precondition for a deliberate correction:
  the pair is minutes old so the nightly linker has not run, and a good correction argues
  about the CONCLUSION rather than restating the vocabulary, so it may never cross the
  similarity threshold at all. The moment you most want to contest an article was the moment
  the mechanism refused (`422 No potential-conflict link exists for this article pair`).

  The asserted pair reaches `knowledge_conflicts` with `origin: "asserted"` and the claim
  (`classification`, `evidence`, an optional proposed winner) attached, and shows up in both
  articles' `potential_conflicts`. `evidence` is required — an assertion carries no
  similarity score, so the argument is what a reviewer judges.

  **Reachability is all it grants.** An assertion retires, hides and down-ranks nothing, and
  does NOT remove either article from curated answers — suppression still requires a system
  flag, or any key could retract any article from the governed answer path by disputing it.
  And the asserting key may not record the pair's verdict: `knowledge_resolve_conflict`
  answers it `409 self_asserted_conflict`, because a party that names a pair does not also
  certify the verdict on it. That is the same separation the `supersede` confidence cap
  already draws between recording a retirement and authorizing one.

  Idempotent per pair, in either direction; re-asserting returns the existing flag with
  `created: false` and never overwrites a system flag's provenance.

### Notes

- **`knowledge_resolve_conflict` still sends `LOOPCTL_AGENT_KEY`**, deliberately. A pair you
  asserted answers `409 self_asserted_conflict` to your own key, and the completion path is
  a DIFFERENT principal — a second session, an orchestrator, or a human operator — not this
  process reaching for `LOOPCTL_ORCH_KEY`. Holding the asserter's key and the judge's key in
  one process makes the separation nominal, and it would also lift the agent-role
  `supersede` confidence cap and the agent visibility scope on every verdict, including the
  system-flagged pairs that have nothing to do with assertions.

## 2.74.0 — 2026-08-12 (one search command, three response shapes)

### Added

- **`knowledge_search` takes `format`: `results` (default), `stubs`, or `bodies`.** These are
  response SHAPES of one search, not different searches — the server dispatches `stubs` to the
  same `progressive_index/3` and `bodies` to the same `get_context/3` that
  `knowledge_progressive_index` and `knowledge_context` call.

  **Nothing is retired.** Both sibling tools remain registered and work exactly as before;
  they are now siblings on one path rather than separate doors to choose between.

  Why it is worth having at all: an agent's choice of entrypoint is unobservable, so it
  confounds any measurement of the ranking behind it — you cannot separate an algorithm's
  effect from a choice you cannot see. A parameter is a variable the server controls; a tool
  choice is a confounder it does not. This is the precondition for judging a ranking change
  from observed behaviour.

  Two refusals, deliberately not silent: `stubs` and `bodies` REQUIRE a query (they are
  relevance shapes; there is no stub rendering of an enumeration page), and an unknown value
  is a 400 rather than a quiet downgrade to `results`. A downgrade would answer a different
  question than the one asked, and an agent could read the result as an empty corpus.

## 2.73.0 — 2026-08-12 (one spelling for the search parameter, plus a body window and prefix-tolerant ids)

### Changed

- **Every search-shaped tool now declares `query`.** Aliasing (2.72.x) rescued the symptom;
  the defect was that one parameter was spelled three ways — `q` on `knowledge_search`,
  `query` on `knowledge_hybrid_search` / `knowledge_context` / `memory_recall` /
  `recall_context`, and `topic` on `knowledge_progressive_index`. The most-used tool was the
  odd one out. `query` is now the canonical spelling in the schemas of all of them; `q` and
  `topic` remain accepted, and an explicit legacy value still wins over the canonical one, so
  nothing that works today stops working.

- **`knowledge_get` and `knowledge_progressive_drill` serve the body in a byte WINDOW**
  (default 32000 bytes), with `body_bytes`, `body_offset`, `body_returned_bytes`,
  `body_truncated` and `next_body_offset` on every response. Four measured reads of 61-82KB
  were rejected client-side by a token cap after the search had already found the article;
  they now come back in parts instead of being discarded whole. Pass `body_max_bytes: 0` for
  the whole body in one read.

- **`knowledge_get` resolves a unique ID PREFIX** (>= 8 hex characters), so a mistyped or
  truncated tail no longer throws away a search that worked. 16 of 20 sampled 404s carried a
  correct 8-character prefix with a confabulated tail. An ambiguous prefix is a 404, never a
  guess.

## 2.72.0 — 2026-08-07 (name the source, so titles can stand alone)

### Added

- **`knowledge_ingest` accepts a `metadata` object, and forwards it.** It previously did
  not, which made `metadata.source_ref` unreachable from MCP entirely — the server honours
  it, but no agent using these tools could set it.

  `source_ref` names the SPECIFIC source (a URL, repo, or document name) and is what lets an
  extracted article title qualify itself. Without it the extractor sees only a coarse
  `source_type` like `web_article` and a CHANGELOG file can only become an article titled
  "Changelog" — indistinguishable from every other document's changelog once it is in the
  corpus. Three unrelated documents did exactly that on the hosted corpus and were then
  proposed for automatic unpublishing as "the same capture".

  It overrides the name derived from `url` (which matters when a URL's identity lives in its
  stripped query string) and is the ONLY way to name the source of an inline `content`
  ingest. **Omit it rather than passing a placeholder** — a model will dutifully qualify a
  title WITH the word "unknown".

### Changed

- **`knowledge_ingest_batch`'s per-item `metadata` documents `source_ref`.** The parameter
  was already accepted and forwarded; its description said only "Optional metadata map", so
  the behaviour was undiscoverable.

### Note on what is sent to your LLM provider

`source_ref` — or, absent it, the ingest `url` reduced to scheme+host+path — is included in
the extraction prompt POSTed to the tenant's configured provider. Userinfo and the query
string are stripped, so credentials and query-string signatures are not transmitted; the
host and PATH are, so a share link carrying its token in a path segment still sends it.

## 2.71.0 — 2026-08-05 (consolidation: two classes retired, and the pass now writes)

### Changed

- **`knowledge_consolidation` no longer describes itself as report-only, and lists two
  classes instead of four** (loopctl issues #605, #606, #608). Nothing about the tool's
  arguments or response shape changed — the description did, because what it reports on did.
  - **The pass writes now.** The nightly run UNPUBLISHES the losers of each
    `duplicate_capture` group that two consecutive reports both propose. That is its only
    write to articles; it is an unpublish and never an archive, because `archived` is
    terminal for an article and an unattended pass may not take a one-way door. The TOOL
    still applies nothing and recomputes nothing.
  - **`contradiction_candidate` is retired** — the nightly lint judges those pairs itself, so
    consolidation was reporting a pile another writer was already draining.
  - **`stale_entry` is retired** — age is not a defect signal, so the class could never earn
    an apply path. For stale articles call `knowledge_lint`, which computes them with a
    caller-chosen `stale_days`.
  - Both retired values are still accepted by the `class` filter and still load from
    historical reports; they are simply never produced again.
  - **`review_status` is vestigial.** Nothing reads it to decide anything, and there is no
    approve/reject surface — auto-apply is gated on reversibility and two-run agreement, not
    on an approval. It still resets to pending whenever the pass re-derives a proposal.

- **`knowledge_delete` and `knowledge_bulk_delete` no longer call archiving "reversible"**
  (loopctl issue #605). `knowledge_archive` was corrected in 2.70.0's tree; these two said
  the same wrong thing and are the sentence a caller reads before archiving something it
  cannot bring back. `:archived` is a TERMINAL article status — there is no unarchive call
  and no outbound transition, so restoring one takes a user-role PATCH with an explicit
  status. Nothing is destroyed and everything is audited; that is what makes single-article
  curation agent-role. When you need a retraction you can actually undo, use
  `knowledge_unpublish` / `knowledge_publish`. No behaviour change — the API always worked
  this way, only the descriptions were wrong. The same correction lands on
  `knowledge_bulk_delete`'s `hard` parameter (which still advertised a "default reversible
  archive" one screen below the corrected tool description) and on `knowledge_update`, whose
  in-place edit overwrites the prior body and so is not reversible either.

## 2.70.0 — 2026-08-05 (the idem- tag namespace is reserved)

### Changed

- **`knowledge_create` / `knowledge_update` — the `idem-` tag prefix is RESERVED** (loopctl
  issue #583). A tag starting with `idem-` must be `idem-<family>-<digest>`, where `<digest>`
  is a 12- or 40-character lowercase hex digest (e.g. `idem-url-7ebe1ca33431`); both lengths
  are accepted because the harvest sourcers' suffix was truncated from a full sha1 to 12.
  Anything else claiming the prefix — `idem-design`, `idem-url-notahex` — is rejected with a
  422, and is NEVER silently re-prefixed, so you always know what was stored. Topical tags
  outside the prefix are unaffected. For idempotent capture use the `idempotency_key` field:
  it has a per-tenant unique index and is server-guaranteed, whereas a tag is caller-controlled
  data. Tool descriptions updated; no schema or transport change.

## 2.69.0 — 2026-08-05 (read the nightly consolidation report)

### Added

- **`knowledge_consolidation`** (issue #584, stage 1 of 3) — reads the nightly consolidation
  ("dream") report: numbered proposals for reconciling the corpus, each naming the articles
  involved and quoting an excerpt from each as evidence. Four classes: `duplicate_capture`
  (title or idempotency-tag format drift — the novelty gate does not catch it because novelty
  scoring and idempotency are separate paths), `contradiction_candidate` (a conflict-flagged
  pair with no recorded verdict — record one with `knowledge_resolve_conflict`),
  `generic_title`, `stale_entry`. **Report only:** the pass writes no articles, links or
  conflict resolutions, every proposal is `pending`, and this tool applies nothing.
  `proposal_count` counts PROPOSALS, not articles — one duplicate group of three articles is
  one proposal — and `persisted_count` is lower exactly when a class hit its per-class cap.
  Requires an orchestrator key. Optional `day`, `class`, `limit`, `offset`.

## 2.68.0 — 2026-08-05 (the precision denominator says what it counts)

### Changed

- **`knowledge_retrieval_metrics` now states its denominator, and reports the per-CALL rate
  separately** (issue #582). The tool said `precision` was "the share of search results the
  agent then opened", and it is — `searched` counts one row per surfaced result, up to the
  20-per-call recording cap. But the name
  reads like a count of searches, and it was read that way: the number was reported as "agents
  open N% of what they find" when the reader meant "N% of searches led to an open", and that
  misreading reached a draft public post. The two are different quantities, so both are now
  reported instead of one being mistaken for the other. `precision` and its `searched`
  denominator are UNCHANGED — redefining a persisted daily series would make every historical
  row incomparable.

- **New response fields**: `results_recorded` (the same number as `searched`, named for its
  unit), `searches` (distinct QUERY-BEARING search CALLS), `searches_with_follow_through` and
  `search_follow_through` (the share of SEARCHES that led to an open — the quantity the
  misreading had in mind), and `results_returned` (the true un-truncated result count for those
  same calls). Only the first 20 results of a search are recorded, so `searched` /
  `results_recorded` is that capped slice — `precision` is precision@20 and an open of a
  result ranked beyond the cap is in neither term — and `results_returned`
  exceeds the rows those calls wrote whenever a page hit that cap. The four call-level fields
  are filtered per ROW, not per day: a row counts only if it carries a search identity (nothing
  recorded before this release does) and is not a query-less enumeration page (`list` /
  `list_keyset` — browsing is not searching), so a day mixing both kinds reports a PARTIAL
  figure rather than 0, and `results_returned` must not be compared against `searched`.

- **The two structural exclusions are documented**: a search returning ZERO results and a
  search made without an api key are unrecordable (an access event requires both an article
  and a key), so they sit in NO denominator and every ratio here is an upper bound. And the
  gaming direction is named: both ratios rise when a search simply returns FEWER results, with
  no better retrieval — read them with the absolute `followed_through` and the volume fields,
  never alone. `search_follow_through` carries two further biases pointing OPPOSITE ways: the
  recording cap hides opens of results ranked beyond it (DOWN), while one open credits EVERY
  search in the window that surfaced that article, not just the preceding one (UP).

## 2.67.0 — 2026-08-04 (one accounting rule for every scope)

### Changed

- **Drilling never adds heat now, at any scope** (issue #572). 2.66.0 exempted tenant-owned
  articles only: a published system canonical's drill still recorded a counted read, because
  the drill was the sole path to its body and excluding it would have frozen every canonical
  at heat 0. That was right about the canon and wrong about the index — `knowledge_heat_index`
  then ranked a counted class against an uncounted one on a single `heat` number, and since
  drilling is the path the payload itself recommends, following the documentation raised only
  canonicals, self-reinforcingly.

- **`knowledge_get` now resolves published system canonicals**, which is what made the
  uniform rule possible: the canon earns heat through a caller-named read like everything
  else, and following a canon stub into `knowledge_get` no longer 404s. **Pick your read tool
  by what it MEANS, not by what it can reach** — both resolve the same ids. A drill is
  uncounted, so following an index never feeds the ranking that produced it; a `get` is a
  counted vote that the article was worth opening on its own. The tool descriptions for
  `knowledge_get`, `knowledge_progressive_drill` and `knowledge_heat_index` all say so.

- **`meta.chars` / `meta.char_budget` are BYTES of the encoded stub array**, array framing
  included. They were graphemes summed per stub, so a CJK or emoji payload was under-reported
  several-fold and the brackets and commas were omitted entirely — both in the unsafe
  direction, for the one number you are told to size a cached prefix against. A budget that is
  wrong by a predictable amount is worse than none, because it is trusted.

- **An explicit `since` on `knowledge_heat_index` is served verbatim.** It was rounded up to
  the next UTC day boundary, silently dropping up to 24h of reads you asked for.

## 2.66.0 — 2026-08-04 (the heat index stops feeding its own ranking)

### Changed

- **`knowledge_heat_index` no longer gains heat from its own drills** (issue #569). The index
  ranks on caller-chosen body reads, and `knowledge_progressive_drill` — the tool this index's
  own payload tells you to use — recorded one. Being shown therefore produced the rank that
  showed it, and material that never surfaced could not overtake material that already had.
  No tool argument changed: the server decides from which read path resolved the article, so
  the exclusion holds for older client releases and for raw HTTP callers too. Drilling a
  tenant article adds no heat (a `knowledge_get` of the same id still does); drilling a
  published system canonical does, because that drill is the only path to its body and
  labelling it uncounted would leave every canonical permanently unrankable. Tool
  descriptions for `knowledge_heat_index` and `knowledge_progressive_drill` now state this.

## 2.65.0 — 2026-08-04 (the query-less retrieval route becomes reachable)

### Added

- **`knowledge_heat_index`** (issue #567). The server shipped a `GET /api/v1/knowledge/heat_index`
  route with no tool in front of it, so the one retrieval path that still works after a silent
  semantic miss was unreachable from the sanctioned client — while the route's own payload told
  the reader to drill with `knowledge_progressive_drill`, an MCP tool.

  Every other retrieval tool starts from a QUERY, so they share one failure mode: a paraphrase,
  or material topically central but lexically dissimilar to the question, comes back empty and
  reads as "the KB has nothing" rather than "I asked badly". This one takes no query at all.
  Optional `category`, `limit`, `since`. Ordering is usage — the number of DISTINCT readers that
  opened each article inside `meta.heat_window` — not relevance to any query.

### Changed

- **`knowledge_progressive_drill`'s description names both indexes it opens.** It said stubs came
  from `knowledge_progressive_index`; it is equally the drill half of `knowledge_heat_index`, and
  a reader who arrived from the heat index had no reason to believe this tool applied to it.

## 2.64.0 — 2026-08-01 (stop paying 4k tokens to read a 735-token article)

### Changed

- **`knowledge_get` link payload trimmed, ranked and capped** (issue #538). Agents are
  told to open every search hit with this tool, so its response is paid on essentially
  every wiki read in every session — and on a measured hub article the links were 12,564
  of 16,189 bytes, roughly 4,000 tokens to read 735 tokens of body.
  - Each link now carries only its **far** side, as `article: {id, title}`. The near side
    was a constant echo of the `article_id` you passed in, with an always-`null` title.
    **Breaking** for anything reading `source_article` / `target_article`; direction is
    unchanged and still given by which array the link is in.
  - Links carry `similarity` when the auto-linker scored them, so a list of otherwise
    identical `relates_to` edges can be ranked or thresholded instead of guessed at.
  - Both arrays are ranked (open `potential_conflict` first, then descending similarity,
    then oldest-first for links the auto-linker never scored — which is every link on a
    hand-created or imported corpus) and capped at 25 per direction. `links_total` and
    `links_truncated` report the truth. Use `knowledge_graph` to traverse the full graph.

### Added

- **`knowledge_get` gains `links`** — `full` (default), `count` (`links_total` +
  `links_truncated`, so one cheap call answers whether the full fetch is capped), or
  `none`. Pass `count`/`none` when you only want the article's text.
  `potential_conflicts` is returned in **all three** modes, so a cheaper read never
  silently turns off conflict discovery; it is itself capped at 25 (strongest first) and
  reports `conflicts_total` / `conflicts_truncated`.

## 2.63.0 — 2026-07-30 (never bank a near-duplicate)

### Added

- **`knowledge_create` gains `skip_low_novelty`** (issue #536). A high-overlap capture is
  normally staged as a DRAFT for review; an UNATTENDED writer has no reviewer, so those
  drafts pile up as corpus debris. Pass `skip_low_novelty: true` and the proposal is
  DROPPED instead — nothing is created, the response reports `skipped: true` with the
  near-neighbour it lost to. Errors are unaffected: an invalid payload, an
  `idempotency_key` retry or a title collision still answer exactly as they do without
  the flag. Mutually exclusive with `force`.

## 2.62.0 — 2026-07-25 (one-call handoff affordance)

### Added

- **`handoff`** (agent) — the SENDER side of a cross-session/cross-machine handoff in one
  call (issue #528, follow-up to #517). Resolves the repo's coordination channel from
  `repo_url`/`slug`/`project_id`, creates a `kind: kb` scope when the repo has no project
  yet, and posts with the stable `handoff:<anchor>` key that makes the handoff
  discoverable and claimable (a same-session repost refreshes the slot in place; the slot
  is keyed per session, so it is not a cross-session singleton). Never attempts
  `create_project`, so an
  agent-rooted tenant reaches the bus instead of a `403 custody_tier_required` wall.
  Reports `channel.created` and the receiver's next three calls.

  Before this, a handoff on a repo with no channel meant hand-assembling
  `resolve_project` → `create_kb_scope` → `channel_post` with the key convention
  documented only at the tail of `channel_post`'s description — the affordance gap #517
  reported and #518 explicitly left out of scope. The receiver flow
  (`channel_handoffs` → `channel_claim` → `channel_done`) is unchanged and deliberately
  not wrapped.

### Changed

- `resolve_project`, `create_kb_scope`, and `channel_post` now delegate to internal
  `*Raw` request functions that `handoff` composes. No behavior change — the composed
  calls are byte-identical to the standalone tools, and each request path is declared
  exactly once.

## 2.61.0 — 2026-07-24 (LCP-1 §9 review hardening — signed-claim delivery + owner rotation)

### Added

- **`custody_sign_owner_rotation`** (local) — sign an owner-key ROTATION proof with
  the OUTGOING owner private key (LCP-1 §9.2), proving possession before it re-roots
  the attestation chain. Binds the old key + its set-at (Unix MICROSECONDS) so the
  proof is not replayable after a rotate-back. Pair with `register_custody_owner_key`'s
  new `rotation_proof` param.
- **`claim` param** on `report_story`, `review_complete`, and `verify_story` — attach
  the signed custody claim from `custody_sign_claim` so it reaches the gate under the
  signed profile (LCP-1 §9.3/§9.4). Optional; ignored under the default bearer profile.
- **`rotation_proof` param** on `register_custody_owner_key` — the outgoing-key
  possession signature required to ROTATE (not first-register) the owner key.

## 2.60.0 — 2026-07-24 (LCP-1 signed custody profile — §9)

### Added

- **`register_custody_owner_key`** (user) — register/rotate the tenant custody
  OWNER key (LCP-1 §9.2), the root of trust for agent-key enrollment. Private half
  stays with the owner; human-anchored.
- **`list_enrolled_agent_keys`** (agent) — LCP-1 §9.1.1 transparency: the enrolled
  agent-key set reconstructed from the tamper-evident audit chain, keyset-paged.
- **`custody_generate_keypair`** (local) — generate an Ed25519 keypair locally; the
  private key never leaves the process.
- **`custody_sign_attestation`** (local) — sign a §9.2 enrollment attestation over
  an agent key, with the owner key (root) or a parent agent key (delegation).
- **`custody_sign_claim`** (local) — sign a §9.3 custody claim; returns a `claim`
  object to attach to a report/review-complete/verify body under the signed profile.

### Changed

- **`dispatch`** now accepts LCP-1 §9.2 signed-profile enrollment fields
  (`agent_pubkey`, `alg`, `attestation`, `attestation_conditions`) to enroll an
  agent key attested by the owner/parent.

### Notes

- The signing helpers are byte-for-byte conformant with the Elixir server
  (`test/custody_signing.test.js` reproduces the checked-in `docs/spec/vectors/LCP-1`
  vectors), so claims signed here verify server-side.
- The signed profile is OFF by default (deployments advertise `bearer`); an operator
  activates it via `custody_signed_profile_enforcement`. These tools are usable for
  enrollment/transparency regardless.

## 2.59.0 — 2026-07-22 (advisory file soft-locks — US-40.4, #451)

### Added

- **`channel_lock`** (agent) — take or refresh an ADVISORY file soft-lock on a repo
  coordination channel: "I'm editing `lib/foo.ex`". It NEVER blocks anyone, nothing
  prevents an edit, and TWO sessions may hold a lock on the same file (both are
  surfaced). Explicitly NOT the exactly-once handoff claim — `channel_claim` remains
  the primitive for "exactly one agent owns this unit of work". Re-locking the same
  target from the same session refreshes it in place (200). The lock carries a SHORT
  server-clamped TTL (`ttl_seconds`, 60..3600 seconds, default 900) and self-expires,
  so a crashed session can never hold a file. `host`/`session_id` stay proxy-supplied;
  a lock write with NO `session_id` is rejected (422) rather than rescued with a
  server-minted surrogate slot that could be neither refreshed nor released.
- **`channel_unlock`** (agent) — release your OWN soft-lock. Addressed by your
  `(tenant, project, agent, session)` slot; a lock you do not hold, another AGENT's,
  one under a different session id, a cross-tenant one, or a nonexistent one all
  return a byte-identical 404. NOTE the enforced scope is per-AGENT, not per-session:
  `tenant`/`agent` are server-stamped, but `session_id` is client-supplied and
  `channel_locks` publishes it, so two sessions sharing one agent key can release
  each other's advisory locks (accepted for hint data).
- **`channel_locks`** (agent) — the PINNED live-lock read for a channel, to call
  BEFORE editing. The read to trust for lock visibility, while `channel_recent`
  admits only the newest few locks so lock churn cannot crowd out real coordination
  posts (and suppressed locks do NOT count toward its `has_more`). Each row carries
  `target`, `agent_id`, `session_id`, `host`, `expires_at` and `inserted_at`, and one
  AGENT contributes at most 20 rows to a page so a noisy locker cannot hide every
  peer's lock. The page reports BOTH truncation modes — `meta.overflow` (page cap)
  and `meta.holders_truncated` (per-agent fairness cap) — so a page that dropped live
  locks is never presented as the complete set. The fairness partition is the
  server-stamped `agent_id` alone: partitioning on the client-supplied `session_id`
  too would let a caller rotating session ids escape the bound entirely.
- Lock targets are PATH-NORMALIZED (`./lib/foo.ex`, `lib//foo.ex`, `/lib/foo.ex` and
  `lib/foo.ex` are ONE slot), so two sessions editing the same file always collide on
  one target instead of each holding a lock the other reads as an unrelated file.

### Changed

- `channel_recent` / `GET /api/v1/channel/posts` rows now carry `lock` (boolean),
  `lock_target` and `expires_at`, so a TEAM CHANNEL renderer can mark an advisory
  lock DISTINCTLY ("claimed: `lib/foo.ex` by beelink, 4m ago") and tell a LIVE lock
  from an expired-but-unswept one without re-deriving the key convention. The by-id
  read (`GET /api/v1/channel/posts/:id`) carries the same three fields.
- The `claim:` key namespace is now RESERVED: `channel_post` with a `claim:`-prefixed
  `key` returns 422 (the `channel_post` tool description says so up front). Previously
  such a post was silently reinterpreted as a soft-lock (900s TTL instead of the
  30-day retention, and surfaced as a bogus file lock). The reservation is
  forward-looking, so the lock reads additionally bound `expires_at` by the soft-lock
  TTL ceiling: a `claim:`-keyed row written BEFORE the reservation keeps its 30-day
  retention and is never published as a live file lock (nor marked `lock: true`).

## 2.58.0 — 2026-07-22 (trust-tier capability discovery — #505)

### Changed

- **`get_tenant`** now documents (and the server now returns) a `capabilities` block:
  which surfaces the tenant's `trust_tier` includes, as `surfaces`
  (`"allowed"` / `"requires_human_anchor"`), `allowed`/`blocked` lists,
  `descriptions`, and `remediation` when anything is blocked. An agent can read the
  tier boundary UP FRONT instead of discovering it via a `403 custody_tier_required`
  on each write.
- **`create_project`** description now states the requirement it actually enforces —
  orchestrator+ role AND a `human_anchored` tenant — and points an agent-rooted caller
  at `create_kb_scope`, which establishes a repo-scoped project row for knowledge
  without a custody surface. Previously the description promised "create a new project
  in the current tenant" with no hint of the tier gate, so an agent-rooted tenant
  could only learn the boundary by taking a 403.
- The `custody_tier_required` **403 body** now embeds the same `capabilities` map (minus
  the static per-surface `descriptions`, which belong on `get_tenant`) plus, where one
  genuinely exists, `remediation.agent_native_alternative` naming the endpoint the caller
  CAN use. The gate itself is unchanged.
- The capability map states its own BOUNDS — `scope: "trust_tier_only"` and
  `applies_to: "mutating_actions"`. The ROLE gate applies independently (an `allowed`
  surface can still return `403 insufficient_role`), and READS stay open on every
  surface, including blocked ones. Without those bounds the map would have relocated the
  confident-then-403 failure onto the role axis and hidden reads a caller is entitled to.
- The **role** 403 (`RequireRole`) now carries a stable `code: "insufficient_role"`,
  `required_role`/`required_roles`, and the same capability block — an agent-role key on
  an agent-rooted tenant was previously halted by the role gate BEFORE the tier gate and
  never saw the alternative.
- `remediation.enrollment_upgrade` is now a machine-actionable object
  (`tools`, `endpoints`, `requires_human`, `docs`) describing the IN-PLACE upgrade —
  enroll an authenticator against the tenant you already own. It was previously a bare
  link to the signup ceremony, which reads as "create a second tenant" and strands the
  knowledge the first one owns.

## 2.57.0 — 2026-07-22 (retention-sweep stall anomalies — #498)

### Changed

- **`get_ingestion_anomalies`** now accepts and documents the third anomaly type,
  `sweep_stalled` — the 30-day channel-post retention sweep is no longer enforcing
  retention for a tenant (expired coordination-bus posts still present well past
  `expires_at`, recorded under the reserved `source_type` `channel_post_sweep`).
  Previously the tool's `anomaly_type` enum admitted only `capture_silence` and
  `high_reject_rate`, so a schema-validating client rejected the new value
  client-side and a discovering agent never learned the retention alarm existed.

## 2.56.0 — 2026-07-21 (per-tenant embedding dimension — US-41.1)

### Added

- **`embedding_status`** (agent) — the tenant's active embedding dimension, whether
  semantic recall is available and the exact reason when it is not, the instance's
  supported dimension set, the shared system corpus's materialization state, and
  per-dimension row counts. This is what to call when semantic search under-returns
  or reports `fallback_reason: semantic_recall_unavailable`.
- **`embedding_materialize_system_corpus`** (agent) — embeds the shared SYSTEM-scoped
  article corpus for THIS tenant at its active dimension with the tenant's own
  credential. Idempotent and batched; system articles are keyword-only until it runs.
- **`embedding_reembed`** (orchestrator) — moves the tenant's whole corpus (articles,
  per-tenant system-article materializations AND agent memories) onto a new dimension.
  Recall keeps serving at the current dimension for the whole run. One-time and
  cost-bearing; orchestrator-role because completion deletes the stale-dimension rows.
## 2.55.0 — 2026-07-21 (witnessed egress custody claim — US-41.7)

### Added

- **`custody_claim`** — the recorded egress custody claim for one article or memory
  row. Not a write-time snapshot: an APPEND-ONLY SEQUENCE of per-operation postures
  (the create, each embedding, each re-embed, each classification/merge), each
  carrying the endpoint loopctl actually resolved for THAT operation and its
  locality verdict. A single snapshot would be falsified the moment an async
  embedding job or an agent-triggered re-embed shipped the body to a different
  endpoint.
  - Three states, and only one of them is an attestation: `no_claim_recorded`
    (no operation sequence was ever assigned — asserts nothing either way),
    `claim_pending` (assigned, batch append not yet flushed; carries the pending
    count and the batch references), and `claim_recorded`, itself `complete` or
    `incomplete`.
  - Completeness is PROVEN: the recorded entries must form a contiguous sequence up
    to a PERSISTED per-row high-water mark (not to the maximum of the rows that
    happen to survive, which would let tail loss restore a satisfied claim). A gap —
    a lost batch job, a dropped append, a deleted entry — is reported `incomplete`,
    NEVER as no-third-party-egress. A fourth reading, `partial_history`, covers a row
    whose recording began after it already existed.
  - `third_party_egress_on_covered_paths` is `false` only when every recorded
    endpoint was NETWORK-local. A tenant-declared endpoint is a public host the
    tenant merely attested is its own, so an all-local sequence resting on one
    reports `"tenant_declared_unverified"` instead.
  - Rides the EXISTING chain-of-custody machinery. Every recorded entry carries a
    `chain_position` in the tenant's hash-chained audit log, and the new public
    `GET /api/v1/audit/sth/{tenant_id}/inclusion/{position}` returns a merkle audit
    path that folds up to the `merkle_root` inside the already-published, ed25519
    signed tree head. No parallel signing scheme.
  - Explicit `coverage` field enumerating which egress paths the attestation covers
    and which it does not, with the reason. The wording stays scoped to the
    endpoints loopctl called for THIS row; it says nothing about what those
    endpoints did with the data afterwards.
- **`custody_failures`** — entries whose chain append was dropped after exhausting
  retries, plus `stale_pending` entries stranded by a flush that died outside its own
  final-attempt branch, so a recording failure is legible rather than silently absent.

## 2.54.0 — 2026-07-20 (pluggable OpenAI-compatible chat endpoint — US-41.3)

### Added

- **`set_llm_config`** gains four params so the CHAT surface (ingest extraction,
  classification, merge synthesis, memory promotion) can run against a tenant's OWN
  OpenAI-compatible endpoint instead of the hardcoded Anthropic one. That surface
  carries the largest and most sensitive payload in the pipeline — a harvested
  document's full text — so a private tier without it would be a guarantee that is
  false in the one place users most assume it holds.
  - `chat_provider` — `anthropic` (default, unchanged) or `openai_compatible`.
  - `chat_base_url` — the API base of your server; the client appends
    `/chat/completions`.
  - `chat_api_key` — the credential for THAT endpoint. A SEPARATE encrypted column
    from `api_key`: your Anthropic key is never transmitted to your host. OPTIONAL:
    omit it for a KEYLESS server (Ollama / llama.cpp / LM Studio / vLLM commonly
    serve `/chat/completions` with no auth) and no authorization header is sent.
  - `acknowledge_key_transmission` — required when CHANGING `chat_base_url` to a NEW
    host without supplying a matching `chat_api_key`; the probe never ships an
    already-stored credential to a new host silently. A same-host re-probe (a model
    change, a key rotation) needs no acknowledgement.

  `extraction_model` is REQUIRED alongside `chat_provider: "openai_compatible"` —
  the per-operation server default is an Anthropic model id no OpenAI-compatible
  endpoint can serve, so there is no safe fallback — and it is the fallback for
  `classification_model` / `merge_model` on that provider.

  The endpoint is PROBED with a trivial completion PER DISTINCT RESOLVED MODEL
  BEFORE anything is persisted: unreachable, auth-rejected and
  not-OpenAI-compatible are distinguished 422s, each carrying an ACTION-REQUIRED
  `remediation`, and nothing is saved on failure. The probe re-runs whenever the
  chat SURFACE changes — provider, base_url, a rotated key or any per-operation
  model — not only when the URL string moves. Because `chat_base_url` is
  tenant-writable it is also held to the SSRF denylist: a host resolving into a
  private/loopback/CGNAT/link-local range is refused unless the OPERATOR
  deployment allowlist carves it out, and a host that cannot be resolved/classified
  at all is refused rather than called unpinned. The write stays **role `:user`** —
  the same PATCH stores tenant secrets.

  `chat_base_url` must be a BARE API base — no query string, no fragment, no
  embedded `user:pass@` credentials (the client appends `/chat/completions` to it,
  and unlike `chat_api_key` the column is NOT encrypted, so anything in the URL is
  stored, audited and echoed back in plaintext). Plaintext `http` is accepted ONLY
  for a host the egress policy classifies network-local — the request carries your
  key AND your full document text, so a public `http://` endpoint is refused with
  `chat_endpoint_plaintext_refused`; use `https`.

  Model ids may contain `/`, so HuggingFace repo ids
  (`meta-llama/Meta-Llama-3-8B-Instruct`, `Qwen/Qwen2.5-7B-Instruct`) — what vLLM,
  TGI, LM Studio and llama.cpp actually serve — are valid `extraction_model` values.

### Changed

- **`llm_config`** now also returns `chat_provider`, `chat_base_url` (echoed — it is
  your own declared host, not a secret), `has_chat_key` and `chat_api_key_hint`.
  No key is ever returned.
- **`knowledge_llm_usage`** rows are now grouped by `provider` as well, so a local
  endpoint's spend is distinguishable from Anthropic's. A local endpoint that
  reports no usage records a row with ZERO tokens — never a silently absent row.

## 2.53.1 — 2026-07-20 (US-41.4 review fixes)

### Changed

- **`declare_trusted_endpoint`** — the purpose enum gains **`ingest`**. Purposes
  are `inference | webhook | ingest`. The content-ingestion FETCH now consults the
  same egress policy module as the provider guard (AC-41.4.9), so a host declared
  for `inference` does NOT authorize loopctl to fetch tenant-supplied URLs from it
  on a `local_only` scope, and vice versa.
- README documents the six egress tools (the designated source of truth for the
  tool list) and the tool count is corrected to 109.

## 2.53.0 — 2026-07-20 (fail-closed no-egress guard — US-41.4)

### Added

- **`egress_posture`** — READ tool at AGENT role over `GET /api/v1/egress/posture`.
  Reports the resolved embedding + chat endpoints for the calling tenant, a
  locality VERDICT for each (network-local / "tenant-declared (unverified
  attestation), not network-local" / non-local), the tenant's declared trusted
  endpoints with their purposes, per-scope `local_only` status and any named
  posture defects. Endpoints are shown; KEYS NEVER ARE. This is how an agent
  VERIFIES locality before harvesting private documents, instead of trusting it.
  The deployment allowlist CONTENTS are deliberately NOT disclosed at agent role
  (operator infrastructure is precisely the target list an SSRF attacker wants):
  at `:agent` the payload carries only a boolean per endpoint saying whether the
  verdict came from the allowlist; contents appear at `:user` and above.
- **`set_local_only`** — ORCHESTRATOR key. Marks a tenant or project scope
  `local_only`, after which loopctl HARD-REFUSES any model-provider call whose
  resolved endpoint is not classified local. Default OFF everywhere. Carries a
  MANDATORY PRE-FLIGHT: refused with `409 would_block_endpoints` naming every
  endpoint that would become `egress_blocked`, unless `acknowledge: true` is
  passed — a silent enable on a vendor-default tenant is a tenant-wide outage
  undoable only by a human key.
- **`clear_local_only`** — EXACT user key. Roles are ASYMMETRIC on purpose:
  tightening is safe to automate, clearing is the self-widening move an agent
  must never make.
- **`declare_trusted_endpoint`** / **`revoke_trusted_endpoint`** — EXACT user
  key. A declaration is an UNVERIFIED TENANT ATTESTATION and is never presented
  as network-local. Public addresses ONLY (checked at write time AND at pin
  time), purpose-scoped (`inference` / `webhook`), vendor hosts excluded. A
  declaration carves NOTHING out of the SSRF denylist — only the
  operator-controlled deployment allowlist can do that, and no role can write it.
- **`egress_repin`** — AGENT key. Recovers from the DISTINCT `:pin_stale` error
  (never conflated with `egress_blocked`) when a declared host's address set
  changes. Agent-role by design: home Ollama boxes, tailscale funnels and DHCP
  VPSes change IP routinely.

### Changed

- `.well-known/loopctl` now publishes instance CAPABILITIES (supported embedding
  dimensions, whether tenant-supplied endpoints are permitted, and the tier
  list), discoverable PRE-AUTH. No tenant-specific data.

### Scope of the guarantee

Fail-closed enforcement covers **every outbound HTTP call made by loopctl
application code** on the MODEL-PROVIDER path, proven by a static chokepoint
check in CI. Webhook delivery is NOT yet covered (US-41.5). HTTP performed
inside a dependency, and this separate `mcp-server/` codebase, are outside the
static check — stated here rather than implied away.

## 2.52.0 — 2026-07-21 (handoff reliability — issue #454)

### Added

- **`channel_post` `supersedes` arg** — retire a stale post by id (US-454 defect
  3). The server marks it `superseded_by` in the same transaction; directed
  discovery excludes it and the history read marks it.
- **`channel_handoffs` `only_mine` arg + `directed_to_me` label** (US-454
  defect 2) — the read is now see-everything by default (addressing is a hint,
  never a filter); `only_mine: true` restores the narrow broadcast + directed-
  to-me view.
- **Process-lifetime session fallback** (US-454 defect 1) — the proxy now sends
  `CHANNEL_SESSION_ID` on every channel post: `CLAUDE_SESSION_ID` when present,
  else one random UUID minted at process start. Keyed (handoff) posts no longer
  depend on the env var reaching this process.

### Changed

- **`channel_post` tool descriptions corrected** — the keyed path no longer
  "requires an active Claude Code session / 422s without one": the server
  derives `handoff:<anchor>` keys from announcing bodies and mints surrogate
  session ids (with `meta.key_source` / `meta.session_id_source` telling the
  sender when a rescue fired). The old description advertised a constraint the
  server no longer enforces.

## 2.51.0 — 2026-07-19 (repo coordination bus — directed-handoff discovery)

### Added

- **`channel_handoffs`** — directed-handoff DISCOVERY read over
  `GET /api/v1/channel/handoffs` on the agent key (Epic 40 Repo Coordination Bus,
  US-40.C1). Surfaces DIRECTED, OPEN, UNCLAIMED handoffs (posts carrying a stable
  `handoff:<anchor>` key) addressed to the caller's `host`/`capabilities` — or
  unaddressed BROADCAST handoffs — that have NO active claim and have not expired.
  It is a SEPARATE, PINNED set: NOT interleaved into and NOT subject to
  `channel_recent`'s newest-N recency truncation, so a `beelink -> mac-mini`
  handoff is always visible to mac-mini even on a busy channel where the newest-5
  preview would drop it. A claim that is DONE keeps its handoff excluded (done is
  terminal); only a released claim or a lease that expired WITHOUT completion
  reopens it. `host`/`capabilities` are ADVISORY filters — they shape WHAT is
  shown, never WHO may read (the result stays bounded to the caller's tenant).
  Oracle-safe: a foreign/nonexistent/malformed `project_id` returns an empty set,
  never a 404. Bodies are BOUNDED previews (<= 512 bytes) of UNTRUSTED DATA
  authored by another agent — fetch a full body via `channel_get`. Required:
  `project_id`.

## 2.48.0 — 2026-07-18 (repo coordination bus — redact/delete)

### Added

- **`channel_delete`** — hard-delete (redact) a coordination post over
  `DELETE /api/v1/channel/posts/:id` on the agent key (Epic 39 Repo Coordination
  Bus, US-39.7). The backstop for a leaked/regretted post: whoever NOTICES a
  leaked secret can remove the row immediately, before its 30-day TTL sweeps it.
  Cooperative single-tenant model — any agent in the tenant may delete any post
  in that tenant (the deleting agent is the audit actor), but NEVER a post in
  another tenant: a foreign or nonexistent id returns a byte-identical 404 (no
  cross-tenant existence oracle). The delete and its `deleted` audit entry run in
  one transaction, so the removal stays accountable even though the row is gone.

## 2.47.0 — 2026-07-18 (repo coordination bus tools)

### Added

- **`channel_post`** — post a coordination message to a repo coordination channel
  (Epic 39 Repo Coordination Bus) over `POST /api/v1/channel/posts` on the agent
  key. A channel IS a `project_id` (a work project or a kb scope); posts are
  tenant-isolated by RLS. This is an agent-role coordination surface, not
  chain-of-custody. `host` is auto-filled from the proxy's `os.hostname()` and
  `session_id` from the Claude Code session id (`CLAUDE_SESSION_ID`) — both
  proxy-supplied and informational (never caller args). Pass a `key` to upsert your
  per-session working-state slot instead of appending a new post; pass optional
  `refs` (`{file, pr, branch, commit}`).
- **`channel_recent`** — read recent posts from a repo coordination channel over
  `GET /api/v1/channel/posts` on the agent key. RLS returns only your own tenant's
  channel (oracle-safe read). Supports `since` (a full ISO8601 instant) and `limit`
  (default 25, max 100).

## 2.46.0 — 2026-07-18 (high-reject-rate ingestion anomalies)

### Changed

- **`get_ingestion_anomalies`** — the `anomaly_type` filter now accepts
  `high_reject_rate` alongside `capture_silence`. `high_reject_rate` flags a
  source_type whose writes are ATTEMPTED but REJECTED at high rate over a rolling
  window (409 title_conflict / validation drops that persist no article row) — the
  complement to capture_silence (writes stopped). Use it to catch the OTHER outage
  signature where knowledge capture is landing calls but silently dropping them.

## 2.45.0 — 2026-07-18 (ingestion-health anomalies)

### Added

- **`get_ingestion_anomalies`** — list ingestion-health anomalies (capture-silence: a
  `source_type` that was producing articles has gone silent) over
  `GET /api/v1/ingestion-anomalies` (orchestrator key). Use it to
  check whether knowledge capture is still landing. Paginated (`page`/`page_size`), with
  optional `source_type`, `anomaly_type`, `resolved` (`false`/`true`/`all`), and
  `include_archived` filters. Complements `get_cost_anomalies`.

## 2.44.0 — 2026-07-17 (KB-scope lifecycle: agent archive + restore)

### Added

- **`archive_kb_scope`** — archive (reversible soft-delete) a `kind: kb` scope you own,
  on the agent key, over `DELETE /api/v1/kb-scopes/:id`. Frees the scope's slot in the
  tenant's `max_projects` budget so an agent-rooted tenant can reclaim KB-scope capacity
  (closes the one-way ratchet from 2.43.0). Rejects a `kind: work` project (422); idempotent
  on an already-archived scope.
- **`restore_kb_scope`** — re-activate an archived `kind: kb` scope (the reverse of archive),
  over `POST /api/v1/kb-scopes/:id/restore`. Re-consumes an active `max_projects` slot (422
  at the cap). Rejects a `kind: work` project (422).

## 2.43.0 — 2026-07-16 (#418 — KB-only project scopes for agent-rooted tenants)

### Added

- **`create_kb_scope`** — create a knowledge-only project scope (`kind: kb`) for
  the current tenant over `POST /api/v1/kb-scopes`, using the AGENT key. Unlike
  `create_project` (a work project, orchestrator+ / human-anchored), a KB scope is
  available to an agent-rooted (KB-tier) tenant: it carries NO work-breakdown /
  chain-of-custody surface (it cannot host epics/stories/dispatch/ui-tests) and
  exists only to partition knowledge articles by repo. Resolve it with
  `resolve_project` and pass the returned `id` as `project_id` on article/knowledge
  writes. Counts toward the tenant's `max_projects` budget.

## 2.42.0 — 2026-07-16 (#411 — agent-memory substrate: resolve_project, recall_context, memory_graduate)

### Added

- **`resolve_project`** (#411 Gap 1) — resolve a repo to its `project_id` in one
  call over `GET /api/v1/projects/resolve`. Accepts any of `slug`, `repo_url`
  (SSH, HTTPS, or bare `owner/repo`), or `name` (precedence `slug > repo_url >
  name`). Use the returned `id` to scope `memory_*` / `recall_context`.
- **`recall_context`** (#411 Gap 2) — ONE round-trip over `POST /api/v1/recall`
  returning the re-ranked `global ∪ active-project` union of long-term MEMORY and
  KNOWLEDGE (combined-search summaries) for a `query`, each result tagged
  `source: memory|knowledge`, plus the untouched per-source `memory`/`knowledge`
  envelopes. Prefer over separate `memory_recall` + `knowledge_search`. Pass
  `project_id` (from `resolve_project`) to merge global with that project.
- **`memory_graduate`** (#411 Gap 3) — graduate one of your long-term memories
  into a durable Knowledge Wiki article over `POST /api/v1/memory/graduate` — the
  explicit, on-demand version of the hourly graduation sweep. DEDUPED by the
  novelty gate (`data.verdict` `created`/`gated_to_draft` → new article, 201;
  `duplicate`/`deduplicated` → canonical article, 200). `re_scope: "global"`
  promotes a project memory tenant-wide on its FIRST graduation. Scope is
  key-derived (foreign/unknown `memory_id` → 404).
- **Publish note.** `resolve_project` and `recall_context` shipped to `index.js`
  in #411 Gaps 1–2 without a version bump, so the published `loopctl-mcp-server`
  (2.41.0) lacked them; this 2.42.0 bump publishes all three new tools together.
  All ride the existing authenticated/witness pipeline (agent key, shared
  `apiCall` + witness-STH). Additive only. Tool count → 89.

## 2.41.0 — 2026-07-11 (US-31.4 — hybrid retrieval + progressive disclosure tools)

### Added

- **`knowledge_hybrid_search`** — single hybrid retrieval entrypoint over
  `POST /api/v1/knowledge/hybrid_search`. Runs the combined keyword+semantic search
  over the full ranked pool, then decides whether a governed **curated** source
  actually answers, returning `meta.provenance` (`curated` | `retrieved`),
  `meta.confidence`, and `meta.curated_article_id`. Provenance rides through the MCP
  boundary verbatim — a curated answer stays flagged `curated`, a retrieved answer
  `retrieved`. Prefer over `knowledge_search` when you want one trustworthy answer
  plus its provenance instead of a ranked list to triage. Degrades to keyword-only
  like `knowledge_search` when embeddings are unavailable.
- **`knowledge_progressive_index`** — progressive disclosure: a cheap, capped index
  of compact stubs (`id`/`title`/`category`/`summary`, no bodies) for a topic,
  curated-preferred and hub-enriched, over `GET /api/v1/knowledge/progressive_index`.
- **`knowledge_progressive_drill`** — opens one stub's full body over
  `GET /api/v1/knowledge/progressive/:id`, resolving both tenant-owned articles and
  published system canonicals.
- All three ride the existing authenticated/witness pipeline (agent key, shared
  `apiCall` + witness-STH). Additive only — existing `knowledge_*` tools are
  unchanged. Tool count 73 → 76.

## 2.40.0 — 2026-07-10 (US-30.5 — dynamic per-tenant Context Retriever tools)

### Added

- **Dynamic MCP tool listing.** `ListTools` now returns the static hand-maintained
  tools PLUS the calling tenant's **generated** Context Retriever tools (Epic 30),
  fetched at listing time from `GET /api/v1/retrieve/tools` through the shared
  authenticated `apiCall` (agent key, same witness/STH path as every read tool).
  When a tenant declares an entity, loopctl auto-generates
  `cr_filter_<entity>_by_<field>` and `cr_search_<entity>` tools over its
  allowlisted columns; those now appear in the agent's tool list automatically. If
  the `/retrieve/tools` fetch fails, the listing **degrades to the static tools**
  (logged, never errors the whole listing). The dynamic fetch uses a **short (5s)
  timeout** and a **positive (30s) + negative (5s) in-process cache** so a
  Context-Retriever backend blip degrades to the static surface fast and does NOT
  re-issue a blocking fetch on every subsequent `ListTools`.
- **Generic dispatch of `cr_`-prefixed calls.** `CallTool` now routes any unknown
  tool name starting with `cr_` to a single generic handler that POSTs to `POST
  /api/v1/retrieve/:entity`. The `(entity, field, operation)` are read from the
  STRUCTURED metadata carried on each generated spec (US-30.2), never by splitting
  the tool name (entity/field names contain underscores). Static tools dispatch
  exactly as before — no regression. Resolving a generated-tool call whose name
  isn't yet cached **forces one fresh `/retrieve/tools` fetch** (bypassing the warm
  TTL) so a tool created server-side since the last listing resolves instead of
  being reported as unknown; a call that stays unresolved returns **503
  temporarily-unavailable** when the tools fetch itself failed (retryable) versus a
  definitive **404** only when the listing was healthy and the name is genuinely not
  this tenant's.

### Review hardening

- **Short timeout + negative caching for the init-time listing fetch.** `ListTools`
  is agent-blocking at connection setup; the generated-tools fetch now carries its
  own short `AbortSignal` budget and negative-caches failures, so a backend outage
  can't stall the whole tool surface (all static tools included) with repeated
  full-timeout blocking fetches. Per-request timeout override threaded through the
  shared `apiCall` → witness client.
- **Defense-in-depth on the `cr_` invariant.** The prefix is re-checked at
  listing/metadata population, not only at dispatch: any server spec whose name
  isn't `cr_`-prefixed, or that collides with a static tool name, is dropped and
  logged — closing a tool-confusion / description-spoofing vector where
  tenant-controlled text could be shown under a trusted built-in tool's identity.
- **Extracted `lib/generated-tools.js`.** The fetch/cache/TTL/negative-cache/
  dispatch runtime moved out of the non-importable `index.js` entry point into a
  side-effect-free module (like `lib/http-helpers.js`), so its edge cases are
  exercised DIRECTLY by the test suite instead of a hand-copied mirror.

### Security / trust model

- Generated tools are **tenant-scoped by construction**: the stdio MCP process is
  one-tenant-per-process, so `/retrieve/tools` returns only the process key's
  tenant's specs and a generic call executes under that key's scope. The client
  never selects a tenant. Both the listing fetch and the generic call ride the
  SAME `apiCall`/witness path as static reads, so they carry identical
  auth + witness/STH headers — no second, weaker HTTP path was introduced.

## 2.38.0 — 2026-07-10 (US-29.4 — memory_promote tool)

### Added

- **`memory_promote`.** A fifth thin tool over the Agent Memory HTTP API (US-29.3,
  `POST /api/v1/memory/promote`) so an agent — or a Claude Code Stop-hook — can
  compile a session's short-term (`session`-tier) memory into durable
  `long_term` memory, once, at session end. Unlike `memory_remember` (a single
  explicit write), `memory_promote` compiles the WHOLE session's session-tier
  memory in one shot. Input is `session_id` ONLY — scope (tenant_id/subject_id)
  is resolved server-side from the API key, so the tool cannot express or
  smuggle a cross-scope promote. Returns 202 Accepted with `{job_id, session_id,
  status: "enqueued"}` — promotion runs asynchronously via an Oban worker, so
  the resulting long-term memory becomes recallable via `memory_recall` only
  after that worker drains. Routes through the shared `apiCall`/witness client
  (same as every other memory_* tool), so witness/STH persistence and the
  transparent bootstrap-412 self-heal apply automatically — no bespoke witness
  code was needed.

## 2.37.0 — 2026-07-09 (US-28.4 — memory_* tools: remember / recall / forget / list)

### Added

- **`memory_remember` / `memory_recall` / `memory_list` / `memory_forget`.** Four
  thin tools over the new Agent Memory HTTP API (US-28.3, `/api/v1/memory*`) so
  an agent can persist/retrieve its OWN scoped, private, accumulated working
  state (running notes, in-flight task context) across sessions — distinct from
  the shared, curated `knowledge_*` wiki. `memory_remember` writes a `long_term`
  (default; embedded asynchronously, semantically recalled) or `session`
  (short-term, TTL-pruned) memory. `memory_recall` semantically searches your
  long-term memories and surfaces `meta.fallback`/`meta.reason`/
  `meta.total_count`/`meta.underfilled` so a degraded (keyword-fallback) recall
  is never mistaken for a genuinely empty scope. `memory_list` paginates your
  memories with `meta.total_count/limit/offset`. `memory_forget` deletes one by
  id (404, no existence leak, on a foreign-scope or unknown id). Scope
  (`tenant_id`/`subject_id`) is resolved server-side from the API key — none of
  the four tools' `inputSchema` accepts a `tenant_id`/`subject_id`, so there is
  no NON-SUPERADMIN way to express a cross-scope read/write from the MCP layer
  (the one carve-out: `memory_list`'s `all_subjects` boolean IS a cross-subject
  read, enforced server-side and a no-op for a non-superadmin key). All four
  route through the shared `apiCall`/witness client, so witness/STH persistence
  and the transparent bootstrap-412 self-heal (#298) apply automatically to a
  fresh MCP process's first memory write — no bespoke witness code was needed.

## 2.36.0 — 2026-07-04 (US-26.7.2 — opt-in WebAuthn trust-tier upgrade ceremony)

### Added

- **`request_authenticator_challenge` / `enroll_authenticator` / `request_authenticator_revoke_challenge` / `revoke_authenticator`.**
  Four thin tools driving the new opt-in WebAuthn trust-tier upgrade ceremony
  (`agent_rooted` -> `human_anchored`) added server-side in US-26.7.2. An
  agent-rooted (KB-tier) tenant created via `signup` can now enroll a
  hardware authenticator to unlock the work-breakdown / chain-of-custody
  surface WITHOUT creating a new tenant or losing its knowledge base. All
  four require the exact `LOOPCTL_USER_KEY` (user role) bound to the target
  `tenant_id` and are explicit that they are **not headless**: completing
  enrollment/revocation requires an interactive WebAuthn client (a browser
  or native FIDO2 library) with a human physically touching the hardware
  authenticator — an agent alone cannot produce a valid attestation or
  assertion. Enrolling a SECOND (backup) authenticator on an
  already-`human_anchored` tenant additionally requires a fresh assertion
  from an existing authenticator (`reauth_assertion`), and revoking a
  tenant's last remaining authenticator is refused server-side (no
  auto-downgrade).

## 2.34.0 — 2026-07-03 (smooth agent BYO-LLM onboarding — self-healing remediation + self-documenting tools)

### Added

- **First-time-setup walkthrough in the README.** A prominent "First-time setup —
  provision your BYO LLM keys" section BEFORE the tool reference walks a stranger
  agent the whole smooth path: sign up → set env (`LOOPCTL_SERVER`,
  `LOOPCTL_USER_KEY`, agent/orch keys) → call `set_llm_config({api_key, embedding_api_key})`
  ONCE → ingest + semantic search work. Explains the strictly-BYO model, which key
  powers what, the per-op model overrides, and that without keys ingest 422s and
  search silently degrades to keyword-only.
- **Self-healing remediation surfaced in tool results.** `knowledge_ingest`,
  `knowledge_ingest_batch`, `knowledge_search`, and `knowledge_context` now lead
  their result with an `ACTION REQUIRED` notice when the server reports a missing
  BYO key — the ingest no-key 422 (`code: no_api_key`) and the search/context
  keyword-only degrade (`meta.fallback_reason: no_embedding_key`) both carry a
  machine-readable `remediation` naming the `set_llm_config` MCP tool, a copy-paste
  example, the REST endpoint, and the onboarding docs. An agent that skips setup
  reads the exact next step instead of a bare error.

### Changed

- **`set_llm_config` / `llm_config` descriptions rewritten to fully onboard a
  stranger agent** — WHAT (provision your OWN Anthropic + OpenAI embedding keys, BYO,
  stored encrypted, never returned), WHY (required before ingest/search; loopctl
  fronts no LLM cost), WHEN (once, at signup), the required `LOOPCTL_USER_KEY`, which
  key powers what, the partial-merge semantics, and that `llm_config` reports
  `has_api_key` / `has_embedding_key` so an agent can CHECK its setup.
- README tool-table rows for `llm_config` / `set_llm_config` now mention BOTH the
  Anthropic AND embedding keys; the `LOOPCTL_USER_KEY` env row notes it is also
  required for first-time LLM-key provisioning.

## 2.33.1 — 2026-07-03 (witness STH persistence + transparent bootstrap-412 retry + cache hardening — #298)

### Security

- **Symlink / file-clobber (CWE-59) closed.** The STH state file is now written
  atomically and symlink-safely: to a private `0600` temp file opened with
  `O_EXCL` (`wx`), then `rename`d over the target — so a pre-planted symlink at the
  cache path is *replaced*, never followed, and can no longer be used to clobber an
  arbitrary victim-owned file on a shared `/tmp`. Loads `lstat` the path and refuse
  a symlinked or foreign-owned file. This also fixes the torn-file race on a killed
  mid-write.
- **Per-(server + key) cache scoping.** The state file AND the in-memory client are
  now keyed by `sha256(serverUrl + ":" + apiKey)`, so two keys/tenants on one host
  no longer share (and clobber) a cache — which previously caused spurious `409
  witness_divergence` responses and false divergence telemetry. Only a non-secret
  hash of the key appears in the filename; the key itself never hits disk.

### Fixed

- **Fresh-tenant zero-STH 409 loop (server-side).** A brand-new tenant has a ~60s
  window before its first STH is sealed; the bootstrap handed out the all-zero STH
  placeholder, which the client echoed and the server then rejected `409
  witness_divergence` (unrecoverable, since the client retry is 412-only). The
  server now treats the zero placeholder as a pass-through while no STH is sealed
  (nothing to diverge from) — gated strictly on there being no sealed STH.
- **Cold-start bootstrap coalescing.** Concurrent tool calls at process start now
  share ONE bootstrap (singleflight) instead of each firing their own.

### Changed

- The transparent retry now anchors to the response `error.code`
  (`witness_bootstrap_already_consumed`), not just the status + header shape.
- `409 witness_divergence` is explicitly NOT auto-retried (the genuine-fork/resync
  signal); the client caches the server's STH so the next request self-heals.
- `LOOPCTL_STH_STATE_PATH` documentation clarified; cache is per-(server + key).

### Added — STH persistence + transparent bootstrap-412 retry (the base feature)

- **Fresh MCP processes no longer fail their first tool call with `412
  witness_bootstrap_already_consumed` (#298).** The witness protocol's one-time
  bootstrap grace is consumed once per API key; every subsequent fresh process
  (a new Claude session, a standalone script, a CI run) reusing a long-lived
  env-var key (`LOOPCTL_AGENT_KEY`, `LOOPCTL_ORCH_KEY`, …) previously started with
  no Signed Tree Head (STH) and tripped that 412. Two client-side fixes:
  - **Transparent retry:** any `412` carrying an `x-loopctl-current-sth` header is
    now caught, the STH is cached, and the SAME request is retried exactly ONCE
    with `X-Loopctl-Last-Known-STH` — so the tool call succeeds instead of
    surfacing the 412. Bounded to a single retry (never a loop). Safe because the
    server's witness plug halts BEFORE the operation runs, so the rejected request
    had no side effect.
  - **Cross-process persistence:** the learned STH is cached to a small state file
    so a FRESH process loads it and sends a real header on its first request,
    avoiding the 412 entirely. Location defaults to a per-server file under the OS
    temp dir (`loopctl-mcp-sth-<hash>.json`) and can be overridden with
    `LOOPCTL_STH_STATE_PATH`. All file I/O degrades gracefully: a missing,
    corrupt, or unwritable state file falls back to in-memory caching + the
    transparent retry above.

### Added

- **`LOOPCTL_STH_STATE_PATH`** env var to override the STH state-file location
  (absolute path). Dispatch-based (v2) clients that mint a fresh ephemeral key per
  dispatch are unaffected by the 412 (each fresh key gets its own clean bootstrap)
  and do not need this.

## 2.33.0 — 2026-07-03 (surface semantic→keyword fallback_reason — #297)

### Changed

- **`knowledge_search`** / **`knowledge_context`** tool descriptions now note that
  when semantic ranking is unavailable the call transparently degrades to
  keyword-only (`meta.fallback: true`, `meta.search_mode: "keyword_only"`) and
  reports a new `meta.fallback_reason` — a stable, non-sensitive tag naming WHY
  (`no_embedding_key`, `embedding_circuit_open`, `embedding_provider_error_<status>`,
  `embedding_timeout`, `embedding_request_failed`, `embedding_crash`,
  `embedding_error`). The reason never leaks an api key or provider body. Combined
  mode additionally reports `meta.semantic_result_count`, so a `0` with
  `fallback: false` (embedding worked but ranking returned nothing) is
  distinguishable from an embedding-failure fallback. Observability only — the
  fallback behavior is unchanged.

## 2.32.0 — 2026-07-03 (per-tenant BYO for embeddings — Epic 28 #179)

### Added

- **`set_llm_config`** now accepts `embedding_api_key` (the tenant's OWN
  OpenAI-compatible embedding key, stored encrypted, never returned) and
  `embedding_model` (free-form; null → server default `text-embedding-3-small`).
  Mandatory BYO: without an `embedding_api_key` the tenant's articles are created
  but are NOT vector-searchable until a key is configured — this closes the
  previously ungated, operator-funded embedding-spend path.
- **`llm_config`** response now also reports `has_embedding_key` +
  `embedding_api_key_hint` (masked last-4) + `embedding_model`. No key is ever
  returned.

## 2.31.1 — 2026-07-03 (usage-window doc clarity + distant_pairs latency — Epic 28 #179 review, loopctl #202/#203)

### Changed

- **`knowledge_llm_usage`** docs now state the 90-day default lookback when `from` is
  omitted and that the EFFECTIVE window is echoed in `meta.from`/`meta.to`, so callers
  can detect that older usage was excluded and widen the window explicitly.
- **`knowledge_distant_pairs`** (`GET /api/v1/knowledge/pairs`) latency fix
  (loopctl #202/#203): the endpoint no longer runs an exact-`total_count`
  `count(*)` query — a full O(candidates²) pass over the sampled self-join that
  could not early-terminate and was ~99% of the ~7.85s prod-scale latency. It now
  returns the paginated page (a `limit+1` look-ahead) alone, well under the Epic 27
  Theme 2 <2s target.

### Deprecated

- **`meta.total_count`** on `knowledge_distant_pairs` is **deprecated and now
  always `null`.** The key is retained (not dropped) for a backward-compat window
  so existing clients get `null` rather than a missing key, but an exact total is
  no longer computed — it is an O(candidates²) cost. **Paginate via `meta.has_more`
  instead.** (This differs from every sibling offset/limit endpoint, whose
  `total_count` stays exact; the self-join's cost is what makes it special.)

### Behavior change

- **`bridge_path=true`** now samples a smaller candidate slice (default 500 vs the
  general 1000) so its per-pair link-graph EXISTS check stays within the <2s budget
  — so a `bridge_path=true` request may surface **fewer pairs** than before for the
  same band. Operator-tunable via `max_bridge_pair_candidates`. `:offset` is also
  now clamped to an operator-tunable ceiling (default 10_000) to bound deep-page cost.

## 2.31.0 — 2026-07-03 (per-tenant BYO Anthropic LLM config + usage — Epic 28, #179)

### Added

- **`llm_config`** / **`set_llm_config`** — get / set-rotate the tenant's OWN Anthropic
  API key (stored encrypted, never returned — only `has_api_key` + a last-4 hint) and the
  three per-operation models. Both require a **user-role** key: they use `LOOPCTL_USER_KEY`
  EXACTLY, bypassing the global `LOOPCTL_API_KEY` override and failing fast if it's unset,
  so a secret-management call never runs under a non-user global key.
- **`knowledge_llm_usage`** — per-tenant LLM token-usage summary (grouped by operation +
  model + source_type + day, optional `from`/`to`, offset/limit pagination). Orchestrator key.

### Note

- Ingesting content now requires the tenant to have configured an Anthropic key
  (`set_llm_config`); `knowledge_ingest`/`knowledge_ingest_batch` return a `422` with
  `code: "no_api_key"` otherwise (mandatory BYO, server #179).

## 2.30.1 — 2026-07-02 (arg-forwarding + apiCall robustness fixes)

### Fixed

- **`list_projects`** now forwards `page`/`page_size` (#247, mcp-01). The dispatch
  called `listProjects()` with no arguments, so the pagination the tool schema
  advertised was silently dropped — a caller asking for `page: 2` always got page 1.
- **`knowledge_ingestion_jobs`** now forwards `limit`/`offset`/`since_days` (#248,
  mcp-02). Same dropped-args class as mcp-01: the dispatch called the handler with no
  arguments, so pagination and the recency window were ignored.
- **`apiCall`** no longer throws on a malformed JSON body (#249, mcp-03). A response
  carrying `Content-Type: application/json` but an empty or truncated body (e.g. a
  transient Fly edge 502/503) made the unguarded `response.json()` throw an unhandled
  exception. The parse is now wrapped so a bad body becomes a structured MCP error
  (`{ error: true, status, body }`) with the HTTP status and a raw-body snippet.

### Internal

- The three fixes above now live in a shared, importable module,
  `lib/http-helpers.js` (`projectsPath` / `ingestionJobsPath` / `parseJsonResponseBody`),
  imported by both `index.js` and the test suite so the tests exercise the code the
  server actually ships instead of a hand-copied mirror. `lib/` is now included in the
  published tarball.
- CI now runs the MCP server's own `node --test` unit suite: a new `mcp-server-ci.yml`
  workflow (on every push/PR touching `mcp-server/**`), and both publish workflows
  (`mcp-autopublish.yml`, `npm-publish.yml`) run `npm test` as a fail-fast gate before
  `npm publish`, so a red suite blocks the npm release. `npm test` is scoped to the
  deterministic unit suite (`test/*.test.js`); the live-network `smoke_test.mjs` is now
  `npm run test:smoke`.

## 2.30.0 — 2026-07-01 (toggleable KB curation log)

### Added

- **`knowledge_curation_log`** — the concise, human-readable feed of KB curation
  adjustments (novelty-gate `gate_duplicate`/`gate_draft`, conflict `supersede`/`merge`/
  `dismiss`), for analyzing the rollout. Recorded ONLY while a tenant has
  `settings.kb_curation_log` on — a per-tenant toggle flipped via the admin tenant API
  (`PATCH /api/v1/admin/tenants/:id` with `settings:{kb_curation_log:true}`); off by
  default = no rows, no overhead. Filter by `kind`/`since`, most recent first.
  Orchestrator role.

## 2.29.0 — 2026-07-01 (retrieval precision metric)

### Added

- **`knowledge_retrieval_metrics`** — the daily retrieval-precision time series (agents'
  KB #3): per day, the share of search results the agent then opened (search →
  get/context within a window). A mechanical proxy for whether retrieval is improving;
  trends up as the corpus is de-duplicated, better navigated, and conflict-resolved.
  Orchestrator role.

## 2.28.0 — 2026-07-01 (route-the-findings: conflict merge)

### Changed

- **`knowledge_resolve_conflict`** — the `merge` disposition is now live: at
  `confidence: "high"` the nightly executor has an LLM synthesize the two articles into
  ONE new **draft** (both sources preserved, never auto-published, for human review).
  Description updated to reflect that (previously "recorded for the later merge step").

## 2.27.0 — 2026-06-30 (route-the-findings: conflict resolution)

### Added

- **`knowledge_resolve_conflict`** — record your verdict on a potential-conflict pair.
  You have the live context the KB lacks; it acts on what you record, never re-judges.
  `dismiss` (false positive) takes effect immediately; `supersede` (with
  `authoritative_article_id`) is applied by the nightly executor at `confidence: "high"`
  (creates a supersedes link + retires the loser, reversible + audited); `merge` is
  recorded for the later synthesis step. Non-destructive at agent role — you record
  intent, the privileged nightly job executes. Last-write-wins per pair.

## 2.26.0 — 2026-06-30 (route-the-findings: conflict review surface)

### Added

- **`knowledge_conflicts`** — list `:potential_conflict` article pairs (published
  articles flagged "too similar to comfortably coexist" by the auto-linker / nightly
  lint sweep), highest-overlap first. The KB only flags; the caller decides
  redundancy-vs-contradiction. Paginated (default 50, max 1000, clamped). Agent role.
- **`knowledge_get`** responses now include a `potential_conflicts` array on each
  article (peer `article_id`, `title`, `similarity`) — so an agent reading an article
  trips over its conflict pairs and can act, instead of digging through the link graph.

### Fixed

- `knowledge_drafts` description/comment corrected: an over-max `limit` is **clamped**
  to the maximum (never rejected with 400) — the server has clamped since the
  pagination work; the tool doc was stale.

## 2.25.0 — 2026-06-30 (novelty-gated write-back)

### Added

- **`knowledge_create`** now documents the server-side **novelty gate** and exposes
  a `force` param. The gate semantically dedups a proposal against the published
  corpus and returns a `gate.verdict`:
  - `duplicate` — a near-identical article exists; **nothing is created** (HTTP 200,
    `deduplicated: true`). Read/update the article at `data.id` instead.
  - `gated_to_draft` — high overlap; created as a **draft** (not published) with the
    near-neighbors in `metadata.proposal_novelty` to merge or publish.
  - `created` — novel, went through normally.
  - `force: true` bypasses the gate. The gate was already enforced server-side; this
    release just makes the tool describe it and adds the bypass knob.

## 2.24.0 — 2026-06-30 (pagination: analytics rankings offset)

### Added

- `offset` on the analytics ranking tools, now that the server endpoints support
  it — page the ranking past the first page:
  - **`knowledge_analytics_top`** — `offset`
  - **`knowledge_unused_articles`** — `offset`

  (`knowledge_agent_usage` / project-usage are bounded summary widgets server-side,
  not enumeration endpoints, so they intentionally take no `offset`.)

## 2.23.0 — 2026-06-30 (pagination: no imposed limits on list tools)

### Fixed

- **`list_ready_stories`** sent a `limit` param, but `GET /stories/ready`
  paginates by `page`/`page_size` — so `limit` was silently ignored and callers
  were stuck on the first page with no way past it. Now forwards `page`/`page_size`.

### Added

- Pagination params on list tools that previously exposed none (so an agent can
  enumerate past the first page):
  - **`list_projects`** — `page`/`page_size`
  - **`get_cost_anomalies`** — `page`/`page_size`
  - **`get_story_token_usage`** — `page`/`page_size`
  - **`knowledge_ingestion_jobs`** — `limit`/`offset`/`since_days` (the server-side
    endpoint is now paginated over full history instead of a hard 50-row / 7-day cap)

## 2.22.0 — 2026-06-24 (bulk-delete: set-based + irreversible hard delete)

### Added

- **`knowledge_bulk_delete`** gains four params for US-27.12:
  - `dry_run` (bool) — preview only, mutates nothing; returns `meta.would_affect`.
    With `hard:true` the preview also returns a single-use `meta.token` (or, for a
    selector larger than the frozen-token bound, a `meta.confirm_hash`).
  - `hard` (bool) — IRREVERSIBLE hard delete (vs the default reversible archive).
    Two-step ceremony: dry-run with `hard:true` to obtain a token, then call again
    with `hard:true` + that `token` to FK-correctly delete the FROZEN id-set
    (article_links removed first, access events cascade). The token is server-minted,
    single-use, and TTL-bounded.
  - `token` (string) — the frozen-set token from the dry-run, required for the hard
    delete.
  - `confirm_hash` (string) — for an oversized hard-delete selector (no token):
    echo back the dry-run's `meta.confirm_hash` to re-confirm the id-set hasn't
    drifted.
  Requires `LOOPCTL_USER_KEY` for every variant (agents/orchestrators get 403).

### Changed

- **`knowledge_bulk_delete` response shape (default soft archive).** The default
  (soft) path is now **set-based** (one statement + one audit event) instead of
  per-row. The response is a backward-compatible superset: `meta.counts`
  (`requested`/`archived`/`skipped`/`not_found`/`errored`) and `meta.count` are
  still present (so existing consumers of the partial-success warning keep working),
  but **`meta.results` is now always `[]`** (the set-based op has no per-id
  breakdown — use `meta.affected`/`meta.counts`), and **`meta.counts.skipped` is
  redefined** as `resolved − affected` (rows already archived/inactive) rather than
  a per-id skip-with-reason. New additive fields: `meta.affected`, `meta.set_based`,
  `meta.op`. A zero-match selector now returns `200` with `affected: 0` (idempotent)
  instead of `400`.

## 2.21.1 — 2026-06-24 (novelty accepts the AC request shape)

### Fixed

- **`knowledge_novelty`** now accepts the documented `texts: [string]` shape (the
  #152 AC / CREATIVITY.md contract) in addition to `ideas: [{text}]`, and also a
  bare `ideas: [string]`. All forms are coerced to idea objects server-side, so
  the documented request shape and the idea-synthesizer consumer agree. The tool
  schema documents both `texts` and `ideas`, and neither is `required` (provide
  one). (#169)

## 2.21.0 — 2026-06-24 (agent-memory trust model enforced)

### ⚠️ Behavior change (server-side)

The agent-memory trust model that 2.19.0 shipped as **advisory-only** is now
**enforced** by the server (#163). This changes what agent-role API keys can
write and read:

- **Write — `agent_id` is bound to the key.** When an **agent**-role key creates
  an article carrying agent-memory metadata (`agent_id`/`memory_type`/`visibility`),
  the server stamps `metadata.agent_id` from the key's verified agent identity,
  overriding any value in the body. An agent can no longer write a memory under
  another agent's identity. An agent key with no agent identity gets **403
  `agent_identity_required`** for such a write. Higher roles (orchestrator/user)
  may still attribute on behalf of others.
- **Read — `visibility` is enforced on EVERY agent-reachable read.** For
  **agent**-role reads, articles whose `metadata.visibility` is `private` or `owner`
  are returned only to the owning agent; others get `404`/exclusion with no existence
  leak. `shared` and non-memory articles are unaffected; higher roles continue to see
  everything. Covered surfaces: `knowledge_get` (incl. its linked-article refs),
  `knowledge_list`/index, `knowledge_search`, `knowledge_context` (incl. linked refs),
  `knowledge_stats`, `knowledge_count`, `knowledge_facets`, `knowledge_graph`,
  `knowledge_suggest_links`, `knowledge_distant_pairs`, `knowledge_random_walk`, and
  `knowledge_novelty` (private priors are excluded from the comparison set). `owner`
  and `private` are enforced identically (owner-only) in this version.

`visibility` scoping is now a real trust barrier for agent keys (not just a
convenience filter). No MCP tool signatures changed.

### Migration note

Identity is the key's registry `agent_id` (a UUID). Memories written **before** this
change with a self-asserted, non-UUID `agent_id` string won't match their owner's key
identity, so the owning agent may no longer read its own pre-#163 private/owner
memories (they remain visible to higher roles).

**Migration path for operators:**
1. Identify affected articles (private/owner visibility with non-UUID agent_id):
   ```sql
   SELECT id, title, metadata->>'agent_id' as agent_id
   FROM articles
   WHERE status = 'published'
     AND COALESCE(metadata->>'visibility', 'shared') IN ('private', 'owner')
     AND metadata->>'agent_id' IS NOT NULL
     AND metadata->>'agent_id' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
   ```
2. For each affected article, determine the correct UUID for its owner (e.g., from agent registry or auth logs).
3. Backfill via REST API (higher-role key required):
   ```
   PATCH /api/v1/knowledge/articles/:id {
     "metadata": {
       "agent_id": "<correct-uuid>"
     }
   }
   ```
   Or treat affected articles as a clean break (keep them archived/read-only to higher roles only).

Memories written after this change are always key-stamped with the API key's UUID.

## 2.20.1 — 2026-06-24 (honest story pagination)

### Fixed

- **`list_stories` / `list_ready_stories`** no longer silently clamp `limit` to 20.
  They default to 20 but now honor an explicit `limit` up to the server's max (500),
  so paging by advancing `offset` no longer skips stories. Tool schemas document the
  `default 20, max 500` contract. (#155)

## 2.20.0 — 2026-06-23 (creativity primitives)

### Added

- **`knowledge_distant_pairs`** — distant-but-bridgeable article pairs in the
  optimal-novelty embedding band (cosine distance min..max, default 0.3–0.7).
  Optional `bridge_path` requires a ≤2-hop link-graph path. Paginated. The
  remote-associates generator for computational-creativity ideation. (#152 A1)
- **`knowledge_novelty`** — score ideas by novelty: each idea's text is embedded
  and compared to the nearest prior proposal (default tag `proposal`), returning
  `novelty_score` = cosine distance (0 = identical, higher = more novel up to 2.0;
  `null` when the idea text is blank, no priors exist, or embedding fails — with
  `meta.prior_count` (count of embedded priors actually compared against)). (#152 A2)
- **`knowledge_random_walk`** — random walk through the link graph from a starting
  article (no cycles), surfacing unexpected connections for incubation. (#152 A3)

  Backed by `GET /api/v1/knowledge/pairs`, `POST /api/v1/knowledge/novelty`,
  `GET /api/v1/knowledge/walk`.

## 2.19.0 — 2026-06-23 (agent-memory scoped context)

### Added

- `knowledge_context` gains agent-memory scoping filters: `memory_types`
  (comma-separated, OR — observation/finding/summary/decision/question/task),
  `agents` (comma-separated agent_ids, OR), and `conversation_id` (exact). These
  filter on the article's `metadata` (JSONB containment), turning the wiki into a
  queryable agent memory scoped to a memory type, agent, or conversation. Server
  validates `memory_type`/`visibility`/`agent_id` conventions on write when an
  `agent_id` is present, and adds a GIN index on `metadata`. (#151)

### ⚠️ Trust Model (v1 Conventions)

- **Agent-memory `agent_id` is self-asserted**, not bound to the authenticated
  API key. An agent can write memories tagged with another agent's identity.
  Operators should assume agents can spoof authorship — do not use agent-memory
  scoping for security-sensitive data. Future versions will bind `agent_id` to
  the API key identity for verified attribution.

- **`visibility` field** (`shared`/`private`/`owner`) is **stored but not
  enforced** in v1. Any authenticated agent can retrieve any other agent's
  memories via `agents=` filters, regardless of visibility. The field is an
  advisory label for future RLS-based enforcement. Treat memory isolation as a
  convenience filter, not a trust barrier.

- Follow-on stories for write-path enforcement (binding `agent_id` to API key,
  `visibility` enforcement) are tracked separately with the operator's explicit
  sign-off. **Superseded by 2.21.0 — both are now enforced (#163).**

## 2.18.0 — 2026-06-23 (suggest typed links)

### Added

- **`knowledge_suggest_links`** — ranked typed-link *candidates* for an article by
  embedding similarity, **read-only** (creates nothing). Excludes the article itself
  and any already-linked article (either direction, any type); only embedded
  published articles. Returns `{id, title, category, similarity_score}` highest-first
  so the caller can create a *typed* link (relates_to/derived_from/contradicts/
  supersedes) — unlike the auto-linker's ambient `relates_to`. Optional `threshold`
  (cosine floor, default 0.5) and `limit` (default 5). Backed by
  `GET /api/v1/knowledge/articles/:id/suggested_links`. (#150)

## 2.17.0 — 2026-06-23 (knowledge graph traversal)

### Added

- **`knowledge_graph`** — multi-hop traversal of the published article-link graph
  from a starting article (depth 1–3). Bidirectional, cycle-safe, bounded to 100
  nodes / 500 edges (`truncated` flags a cap hit). Returns `nodes`
  (id/title/category/depth) + `edges` (source/target/relationship_type) so agents
  can explore typed connections beyond the 1-hop links in `knowledge_context`.
  Backed by `GET /api/v1/knowledge/graph`. (#149)

## 2.16.0 — 2026-06-23 (bulk unpublish)

### Added

- **`knowledge_bulk_unpublish`** — revert published articles to draft in bulk,
  partial-success style (the mirror of `knowledge_bulk_publish`). REQUIRES
  `LOOPCTL_USER_KEY`. Per-id outcomes (`unpublished`/`skipped`/`not_found`/
  `errored`), de-duplicated, auto-chunked, ≤5000/call; surfaces a warning when the
  run is partial. Articles are not deleted (re-publish to restore; use
  `knowledge_bulk_delete` to archive). Completes #148 M3. (#148 A6/M3)

## 2.15.0 — 2026-06-23 (AND-tag filtering + count/facets)

### Added

- **`knowledge_count`** — count articles matching filters (category, status, tags,
  `match`, source/idempotency, project) **without returning rows**. With
  `tags` + `match: "all"` (+ `status`) it answers "how many published articles
  tagged both X and Y" in one call. (#148 A2/A4)
- **`knowledge_facets`** — count articles grouped by distinct tag, with an
  optional `tag_prefix` to get the **distinct count of a tag family** (e.g. how
  many distinct `book-*` books) plus per-member totals, no row enumeration. (#148 A3)
- **`match` param** on `knowledge_list`, `knowledge_index`, and `knowledge_search`:
  `any` (default, OR — back-compat) or `all` (AND — articles carrying every listed
  tag). Lets agents ask for "book hubs" (`tags: "book,hub", match: "all"`) instead
  of the union. (#148 A2 / M1)

## 2.14.0 — 2026-06-23 (lag-free enumeration honors large pages)

### ⚠️ Breaking Change

- **`knowledge_list` is now body-less by default**: it returns an article
  *summary* (id, title, category, status, tags, source/idempotency fields,
  timestamps) and **no longer includes `body`** unless you pass
  `include_body: true`. This makes large enumeration (the tool's main job: dedup/
  repair/existence checks) safe to page up to `limit=1000` without ~100 MB
  responses. With `include_body: true` the page is bounded by a ~5 MB
  serialized-body budget and may return fewer than `limit` rows — continue via
  `meta.next_offset` while `meta.has_more` is true. For a single full body use
  `knowledge_get`; for the relevant bodies use `knowledge_context`; for a bulk
  content dump use `knowledge_export`. Callers that read `body` from
  `knowledge_list` rows must either pass `include_body: true` or switch to one of
  those tools.
- **`knowledge_drafts` behavior envelope changed**: Requests with `limit` values
  between 21–1000 now return up to 1000 rows (previously silently clamped to 20).
  Requests with `limit > 1000` now return **400 Bad Request** (previously
  succeeded and returned ≤20 rows). Callers relying on "drafts enumeration never
  errors" or "drafts requests always fit in a 20-row buffer" will need updates.
  Draft rows now also carry the full body bounded by the same ~5 MB byte budget.

### Changed

- `knowledge_drafts` now passes `limit` through to the server (like
  `knowledge_list`/`knowledge_index`/`knowledge_search`) instead of silently
  clamping it to 20 client-side. The server honors a page size up to 1000 and
  returns **400** for a larger limit — never a silent clamp — so draft
  enumeration via offset/limit reaches every row. Schema `maximum` raised
  20 → 1000. Note: Schema `maximum` is advisory; servers always enforce the cap
  at the API layer with a 400 error.
- `knowledge_list` schema documents the raised max page size (100 → 1000) and the
  honor-or-400 contract, matching the server change for #148 A1.

### Fixed

- Closes the MCP half of the #148 A1 silent-truncation bug: a draft enumeration
  requesting `limit > 20` previously received only 20 rows while the caller, if
  advancing `offset` by the requested limit, skipped the rest.

## 2.13.0 — 2026-06-22 (ingest publish opt-in)

### Added

- `knowledge_ingest` and `knowledge_ingest_batch` accept `publish: true` to
  publish extracted articles immediately. Ingested (LLM-extracted) articles
  remain **drafts by default** — lower-trust output staged for review, distinct
  from `knowledge_create`'s publish-by-default — but can now be published in one
  step. `knowledge_ingest_batch` supports a batch-level `publish` default and a
  per-item override. Completes loopctl #133 (the ingest half).

## 2.12.0 — 2026-06-22 (knowledge_bulk_delete)

### Added

- New `knowledge_bulk_delete` tool (requires `LOOPCTL_USER_KEY`): bulk
  soft-delete (archive), partial-success. Selectors: `article_ids`,
  `source_type`+`source_id` (dedup cleanup), or `tag`+`confirm:true`
  (high-blast-radius, confirm required). Per-id outcomes
  (archived/skipped/not_found/errored) in `meta.results`; idempotent
  (already-archived skipped); auto-chunked, ≤5000/call; emits a warning when
  the run is partial. Wraps the new `POST /api/v1/knowledge/bulk-delete`. (loopctl #136)

### Note

- 429 responses carry a `Retry-After` header (always ≥1s) plus
  `X-RateLimit-*`; default limit 300 req/min/key (3x/tenant). (loopctl #136)

## 2.11.0 — 2026-06-22 (knowledge_list: lag-free enumeration)

### Added

- New `knowledge_list` tool: lists articles with full fields (status, tags,
  source_type, source_id, idempotency_key, timestamps), filtered by
  tags/status/source_type/source_id/idempotency_key/category and paginated. It
  wraps `GET /api/v1/articles` — the lag-free, all-status read of the DB of
  record — so MCP-only clients can enumerate/dedup/repair and run idempotency/
  existence checks reliably right after a write, instead of the ranked,
  published-only, write-lagging `knowledge_search`. (loopctl #134, #135)
- `GET /api/v1/articles` now also filters by `source_type`, `source_id`, and
  `idempotency_key`.

## 2.10.0 — 2026-06-22 (knowledge_create idempotency_key + provenance)

### Added

- `knowledge_create` now accepts `idempotency_key` for idempotent capture:
  re-creating with the same key is a clean no-op that returns the existing
  article (`deduplicated: true`) instead of a partial duplicate — distinct from
  `source_type`/`source_id`, which mark a shared source across many articles.
- `knowledge_create` now forwards `source_type` and `source_id` (previously
  dropped by the tool) so provenance can be recorded on create. (loopctl #137)

## 2.9.0 — 2026-06-22 (knowledge_bulk_publish partial success)

### Changed

- `knowledge_bulk_publish` is now **partial-success** and **idempotent**: every
  valid draft is published; other ids are reported per-id as `skipped` (already
  published, or archived/superseded), `not_found`, or `errored` instead of
  failing the whole call with a 422/404. The **100-id cap is removed** (larger
  requests are auto-chunked server-side) and duplicate ids are de-duplicated.
  The response gains `meta.counts` and `meta.results`; `meta.count` still equals
  the number actually published. Safe to retry. (loopctl #132, #138)

## 2.8.0 — 2026-06-22 (knowledge_create publishes by default)

### Changed

- `knowledge_create` now **publishes on create by default** for every role
  (including agent), making the article immediately visible in
  search/index/context — no separate publish step or orchestrator key needed.
  The previous `publish: true` flag is replaced by `draft: true`, which stages
  the article for later review instead (publish it afterwards with
  `knowledge_publish`). This eliminates the most common place harvested
  knowledge silently rotted as an invisible draft. (loopctl #133)

## 2.7.0 — 2026-06-19 (knowledge_create publish-in-one-call)

### Added

- `knowledge_create` accepts `publish: true` to create-and-publish in one call.
  A publish request is routed through `LOOPCTL_ORCH_KEY` (orchestrator role,
  mirroring `knowledge_publish`); the server returns 403 if that role is
  missing. On an agent-only install (no `LOOPCTL_ORCH_KEY`/`LOOPCTL_API_KEY`) a
  `publish: true` request returns a clear "requires orchestrator role" tool
  error instead of a cryptic keyless failure. Without publish, articles are
  still created as **draft**.

### Changed

- The `knowledge_create` description now states up front that articles are
  created as a draft and are NOT visible to agents until published, and the
  underlying `POST /articles` response carries a `note` making the draft (or
  published) outcome explicit (issue #120). The two-step draft→publish flow was
  easy to miss, leaving articles silently invisible.

## 2.6.1 — 2026-06-19 (search total_count clarity)

### Changed

- `knowledge_search` responses now include `meta.total_count_scope`, a
  self-describing label for what `meta.total_count` counts in the active mode
  (`keyword_matches`; `ranked_corpus` = embedded published set, ≤ published
  count; `merged_candidates` = deduped union of two 50-capped sub-searches, up
  to ~100; or `filtered_set`), plus `meta.search_mode`. The tool description
  documents the per-mode
  semantics and stop-word behavior so callers stop misreading `total_count` as
  a corpus total (issue #119). For sizing the wiki, use list mode or
  `knowledge_stats`.

## 2.6.0 — 2026-06-19 (knowledge_stats)

### Added

- `knowledge_stats` — aggregate article counts (`{ total, by_category,
  by_status }`) via a cheap `COUNT(*) GROUP BY`, with no article metadata
  loaded. This is the tool to answer "how many articles are in this project?":
  `knowledge_index` pages article metadata (capped per request) and
  `knowledge_search`'s `total_count` is query-dependent, so neither could give a
  reliable project total (issue #118). Optional `project_id` scopes the counts.
  Backed by `GET /api/v1/knowledge/stats` (and the project-scoped variant).

## 2.5.0 — 2026-06-19 (knowledge_index field projection)

### Added

- `knowledge_index` now accepts a `fields` projection (default
  `id,title,category`; request `tags`/`status`/`updated_at` explicitly; `id`
  and `category` are always included). Previously the index always serialized
  every metadata field — including the `tags` array — for up to 1,000 articles
  per page, producing payloads large enough to overflow an MCP client's token
  limit (issue #117). The default projection keeps the catalog small while
  leaving the heavier fields available on request. `meta` echoes the applied
  `fields` and adds `has_more` (a synonym for `truncated`).

## 2.4.1 — 2026-06-18 (Concurrency-safe article create)

### Changed

- `knowledge_create` (and the underlying `POST /articles`) is now concurrency-
  safe. A create that races/retries into the `(tenant_id, title)` active unique
  index no longer returns a spurious `422 "tenant_id has already been taken"`:
  if the colliding payload has an **identical body** (ignoring surrounding
  whitespace — the unforgeable server-side content signal) the existing article
  is returned idempotently (HTTP 200); a **different-body** same-title collision
  returns a clear `409 title_conflict`
  (with the existing article id) instead of a 422 the client retries into. The
  unique-violation message is also corrected to be attributed to `title` rather
  than the misleading `tenant_id`. Fixes #113/#114.

## 2.4.0 — 2026-06-18 (OKF interchange)

### Added

- `knowledge_okf_export` — export the wiki as a portable OKF (Open Knowledge
  Format) v0.1 bundle: a tree of markdown files with YAML frontmatter. Writes
  the bundle to `out_dir` (one `.md` per concept, plus `index.md`/`log.md`) or
  returns it inline as `{files, meta}`. Requires `LOOPCTL_USER_KEY`.
- `knowledge_okf_import` — import an OKF bundle from a local directory. Reserved
  files are skipped; each concept is created or (with `merge`, default true)
  updated in place when it matches an article we previously imported. Unknown
  frontmatter types/keys are tolerated and preserved; all imports land as drafts.
  Returns a per-file report. Requires `LOOPCTL_USER_KEY`.

### Rationale

OKF (Google Cloud's vendor-neutral spec, v0.1) makes the wiki portable —
git-shippable, GitHub-renderable, and interoperable with other agents/tools —
as an interchange layer without changing loopctl's DB-backed internals. Both
tools stay at `role: :user` because export is a bulk knowledge egress and import
bulk-mutates curated articles.

## 2.3.0 — 2026-06-18 (Knowledge enumeration & pagination)

### Added

- `knowledge_search` now accepts `offset` for pagination, and `q` is now
  **optional** when `tags` and/or `category` are supplied. In that list mode the
  server returns the complete filtered set (no relevance ranking) paginated via
  `offset`/`limit` over `meta.total_count`, so an agent can enumerate every
  article carrying a tag/category instead of unioning many keyword queries.
  Fixes #108.
- `knowledge_index` now accepts `category`, `tags`, `offset`, and `limit`.
  Results are ordered deterministically so pagination reaches every article
  (previously a fixed cap silently dropped whole categories), and
  `meta.categories` reports per-category totals over the entire filtered set.
  An unknown `category` is rejected with `400` rather than silently ignored.
  Fixes #109.

### Rationale

There was no reliable way to enumerate all articles for a given tag/category:
`knowledge_search` forced a keyword that was AND-ed with the filter and capped
per query, and `knowledge_index` silently ignored `category`/`tags`/`offset`
while truncating later categories. Both paths now support complete, paginated
enumeration.

## 2.2.0 — 2026-04-22 (Wiki curation tools)

### Added

- `knowledge_unpublish` — revert a published article back to draft. Hides it
  from agent search/context without deleting; re-publish via
  `knowledge_publish`. Requires `LOOPCTL_USER_KEY` (destructive, `role: :user`).
- `knowledge_archive` — soft-delete an article (draft or published). Hidden
  from search/context/index; row retained for audit. Requires
  `LOOPCTL_USER_KEY`.
- `knowledge_delete` — alias for `knowledge_archive` (DELETE verb on the REST
  API archives under the hood). Requires `LOOPCTL_USER_KEY`.

### Rationale

Previously agents could create and publish articles but had no way to retract
bad drafts via MCP — low-signal articles (session summaries, commit recaps)
were piling up in the wiki with no cleanup path short of curl. These three
tools close the curation loop. All three stay at `role: :user` per the
"destructive ops above orchestrator" rule in `CLAUDE.md`.

## 2.1.0 — 2026-04-17 (Agent ergonomics)

### Added

- `import_stories` now accepts `merge: true` to append stories to epics that
  already exist (previously duplicates returned 409 with no way forward).
- `import_stories` now accepts `payload_path` (absolute JSON file path) so
  large imports can bypass inline tool-call size limits. When both
  `payload` and `payload_path` are passed, inline wins.
- `create_story` — create a single story inside an existing epic. Accepts
  either `epic_id` (UUID) or (`project_id` + `epic_number`). No more
  wrapping a single story in a bulk import payload.
- `backfill_story` — mark a story as verified when the work was completed
  outside loopctl. Records provenance (`reason`, `evidence_url`,
  `pr_number`) in `metadata.backfill` plus an audit entry and a
  `story.backfilled` webhook. Refused for any story with dispatch
  lineage (non-pending `agent_status`, `assigned_agent_id`,
  `implementer_dispatch_id`, or `verifier_dispatch_id` set) — cannot be
  used as a chain-of-custody shortcut.

### Changed

- `import_stories` is type-tolerant on epic numbers. Integer and numeric
  string both normalize to integers before DB lookup, fixing the
  `epics[0].tenant_id: has already been taken for this project` error
  when clients serialized epic numbers as strings.
- `resolvePayload` validates `payload_path` before reading: requires an
  absolute path, refuses `/proc`, `/dev`, `/sys` prefixes, rejects
  non-regular files, enforces a 5 MiB size cap.
- Domain error translation for Epic/Story unique-number violations —
  duplicate imports and direct creates now return
  `"Epic 72 already exists in this project. Use merge=true..."` instead
  of the raw Ecto constraint message.

## 2.0.0 — 2026-04-12 (Chain of Custody v2)

### Breaking

- **Dispatch pattern required**: The shared `LOOPCTL_AGENT_KEY` pattern is
  replaced by per-dispatch ephemeral keys minted via `POST /api/v1/dispatches`.
  After the epic merge, long-lived agent keys without a dispatch association
  will fail with `403 missing_dispatch`.

### Added

- `dispatch` tool wraps `POST /api/v1/dispatches`. Mints ephemeral api_keys
  for sub-agents with bounded TTL and lineage tracking.
- Tool description includes ephemeral key handling instructions.

### Changed

- Version bumped from 1.2.0 to 2.0.0 (semver breaking change).
- All existing tools continue to work unchanged.

---

## 1.2.0 — 2026-04-11

### Added

- `knowledge_search`, `knowledge_get`, `knowledge_context`, `knowledge_index` now accept optional `story_id` (UUID) parameter. When present, forwarded as a query param so the server can attribute the wiki read to the active story. (US-25.3, AC-25.3.1–25.3.4)
- `knowledge_get` also gains optional `project_id` parameter (the other three already had it).
- `knowledge_agent_usage` now accepts `api_key_id` (the `api_keys.id` credential) OR `agent_id` (the `agents.id` logical identity). Passing both is a validation error. Passing neither is a validation error. The tool description explains the difference. (US-25.3, AC-25.3.5)
- When `agent_id` alone is passed to `knowledge_agent_usage`, the response includes `_meta.deprecation_hint` nudging callers toward explicit `api_key_id` for credential lookups. (US-25.3, AC-25.3.6)
- README: new "Wiki Attribution" section explains context params, api_key_id vs agent_id disambiguation, and the deprecation path. Includes example workflow snippets. (US-25.3, AC-25.3.7–25.3.8)
- Test suite bootstrapped at `test/knowledge_tools.test.js` using Node.js built-in `node:test`. Run with `npm test`.

### Changed

- All four wiki read tool descriptions shortened and updated with the one-line nudge: "Pass story_id when working on a loopctl story so reads attribute correctly." (AC-25.3.9)
- `knowledge_agent_usage` description rewritten to explain the new `api_key_id`/`agent_id` split.
- `package.json`: added `"test": "node --test test/"` script.
- Server version string updated to `1.2.0`.

### Deprecated

- `knowledge_agent_usage` with a single `agent_id` parameter (old behavior: `agent_id` meant `api_keys.id` credential). Now `agent_id` refers to the logical `agents.id`. Use `api_key_id` for the credential. A `_meta.deprecation_hint` is included in the response when `agent_id` alone is used. Will be cleaned up in a future release.

## 1.1.2 — prior release

Initial public release. See git history for details.
